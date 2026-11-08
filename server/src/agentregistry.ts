import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { accessSync, chmodSync, constants, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, delimiter, dirname, join, resolve, sep } from "node:path";
import { promisify } from "node:util";
import { cleanEnv } from "./agentenv.ts";
import { agentUser, runAsAgent } from "./agentuser.ts";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";

const run = promisify(execFile);

/** The Agent Client Protocol's own list of agents, with how each is installed. */
export const REGISTRY_URL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
const REGISTRY_TTL_MS = 60 * 60 * 1000;
const MAX_DOWNLOAD_BYTES = 500 * 1024 * 1024;

// What the registry says becomes folder names and command arguments, so it has to look like what it should be.
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const PINNED_NPM = /^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._+-]*$/;
const PINNED_UV = /^[A-Za-z0-9][A-Za-z0-9._-]*(==|@)[A-Za-z0-9][A-Za-z0-9._+-]*$/;

interface Launch {
  args?: string[];
  env?: Record<string, string>;
}
interface PackageLaunch extends Launch {
  package: string;
}
interface BinaryLaunch extends Launch {
  archive: string;
  cmd: string;
  sha256?: string;
}

/** One agent as the registry describes it. */
export interface RegistryEntry {
  id: string;
  name: string;
  description?: string;
  version?: string;
  website?: string;
  repository?: string;
  distribution: { npx?: PackageLaunch; uvx?: PackageLaunch; binary?: Record<string, BinaryLaunch> };
}

/**
 * An agent the app can offer, and where it stands on this server: one of the agents that come with Kervan, already
 * added, found installed on the server, installable from here, or neither (with why).
 */
export interface OfferedAgent {
  id: string;
  name: string;
  description: string;
  version?: string;
  website?: string;
  status: "builtin" | "added" | "found" | "installable" | "unavailable";
  /** How it would be installed. */
  source?: "npm" | "download" | "uvx";
  /** Where it was found, for "found". */
  path?: string;
  /** Why it can't be added from here, for "unavailable". */
  reason?: string;
  /** It can be set up to use a local model from this machine's Ollama or LM Studio. */
  ollama: boolean;
  /** The local models it has been added with on this machine already. */
  addedModels?: string[];
}

export interface OllamaStatus {
  running: boolean;
  url: string;
  models: string[];
}

/** What a client asked to add: the agent, and at most one local model to run it with. */
export interface InstallRequest {
  agentId: string;
  ollamaModel?: string;
  lmStudioModel?: string;
}

/**
 * The catalog id of an agent added with a local model, so each model is an agent of its own. Hashed, node included,
 * because ids are short and model names aren't valid in them; undefined when no model was asked for.
 */
export function localModelAgentId(request: InstallRequest, node?: string): string | undefined {
  const model = request.ollamaModel ? `ollama:${request.ollamaModel}` : request.lmStudioModel ? `lmstudio:${request.lmStudioModel}` : undefined;
  if (!model) return undefined;
  return `${request.agentId}-${createHash("sha256").update(`${node ?? ""}\n${model}`).digest("hex").slice(0, 8)}`;
}

const localModelAgentName = (agent: string, model: string) => `${agent} (${model})`;

/**
 * Says which local models each offered agent already runs on this machine. By name, the one thing shared with agents
 * added before each model had its own id; a renamed one only loses its mark, and adding it again is harmless.
 */
export function markAddedModels(agents: OfferedAgent[], models: string[], names: Set<string>): OfferedAgent[] {
  return agents.map((agent) => {
    const addedModels = agent.ollama ? models.filter((model) => names.has(localModelAgentName(agent.name, model))) : [];
    return addedModels.length > 0 ? { ...agent, addedModels } : agent;
  });
}

/** The agent definition to save once installed, in the shape `AgentCatalog.save` takes. */
export interface InstalledAgent {
  id: string;
  name: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
  authMethod?: string;
}

// Registry ids of the agents Kervan already ships, mapped to Kervan's own ids.
const BUILTIN: Record<string, string> = { "claude-acp": "claude", "codex-acp": "codex", gemini: "gemini" };

// Command names that differ from both the package name and the archive's file name.
const COMMAND_NAMES: Record<string, string[]> = {
  "qwen-code": ["qwen"],
  "github-copilot-cli": ["copilot"],
  "factory-droid": ["droid"],
  cursor: ["cursor-agent"],
  "mistral-vibe": ["vibe-acp", "vibe"],
};

/**
 * Agents that can run a local model from Ollama, and the settings that point them at it. Goose reads its provider
 * from its environment; Qwen Code speaks to Ollama's OpenAI-compatible endpoint and signs in with that method.
 */
const OLLAMA_SETUP: Record<string, (url: string, model: string) => { env: Record<string, string>; authMethod?: string }> = {
  goose: (url, model) => ({ env: { GOOSE_PROVIDER: "ollama", GOOSE_MODEL: model, OLLAMA_HOST: url } }),
  "qwen-code": (url, model) => ({
    env: { OPENAI_BASE_URL: `${url}/v1`, OPENAI_API_KEY: "ollama", OPENAI_MODEL: model },
    authMethod: "openai",
  }),
};

/** LM Studio has no API key by default and speaks OpenAI's protocol, which is how both agents reach it. */
const LM_STUDIO_SETUP: typeof OLLAMA_SETUP = {
  goose: (url, model) => ({ env: { GOOSE_PROVIDER: "openai", GOOSE_MODEL: model, OPENAI_HOST: url, OPENAI_API_KEY: "lm-studio" } }),
  "qwen-code": (url, model) => ({
    env: { OPENAI_BASE_URL: `${url}/v1`, OPENAI_API_KEY: "lm-studio", OPENAI_MODEL: model },
    authMethod: "openai",
  }),
};

// Its port differs between machines and a service user can't read its settings, so the usual ones are tried.
const LM_STUDIO_URLS = ["http://127.0.0.1:1234", "http://127.0.0.1:1235"];

// Long enough for a large model to load into memory first.
const TOOL_CHECK_TIMEOUT_MS = 5 * 60_000;

/** This machine in the registry's terms, e.g. "linux-x86_64". */
export function platformKey(platform: string = process.platform, arch: string = process.arch): string {
  return `${platform === "darwin" ? "darwin" : platform === "win32" ? "windows" : "linux"}-${arch === "arm64" ? "aarch64" : "x86_64"}`;
}

/** "@scope/name@1.2.3" → "@scope/name"; "name@1.2.3" → "name". */
export function packageName(spec: string): string {
  const at = spec.lastIndexOf("@");
  return at > 0 ? spec.slice(0, at) : spec;
}

/** The names an agent's command may have on PATH, most likely first. */
export function commandNames(entry: RegistryEntry, platform = platformKey()): string[] {
  const names = [...(COMMAND_NAMES[entry.id] ?? [])];
  const binary = entry.distribution.binary?.[platform];
  if (binary) names.push(basename(binary.cmd));
  for (const spec of [entry.distribution.npx?.package, entry.distribution.uvx?.package]) {
    if (spec) names.push(basename(packageName(spec.replace(/==.*$/, ""))));
  }
  names.push(entry.id);
  return [...new Set(names.filter(Boolean))];
}

function executable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Where the service user's PATH and the usual install places point. Read on every call, for tests. */
function searchFolders(): string[] {
  const home = homedir();
  const extra = [join(home, ".local/bin"), join(home, "bin"), join(home, ".opencode/bin"), join(home, ".cargo/bin"), "/usr/local/bin"];
  return [...new Set([...(process.env.PATH ?? "").split(delimiter), ...extra].filter(Boolean))];
}

/** The first of `names` installed on this server, if any. */
export function findCommand(names: string[], folders = searchFolders()): string | undefined {
  for (const name of names) {
    for (const folder of folders) {
      const path = join(folder, name);
      if (existsSync(path) && executable(path)) return path;
    }
  }
  return undefined;
}

/** `OLLAMA_HOST` as a URL; Ollama itself accepts it without a scheme or port. */
export function ollamaURL(host = process.env.OLLAMA_HOST): string {
  const value = (host ?? "").trim() || "127.0.0.1:11434";
  const withScheme = /^https?:\/\//.test(value) ? value : `http://${value}`;
  const url = new URL(withScheme);
  if (!url.port && !/^https?:\/\/[^/]+:\d+/.test(withScheme)) url.port = "11434";
  return url.origin;
}

/**
 * Why `model` can't run an agent, or undefined if it can: one real tool call, because the apps' own lists can't be
 * trusted. Ollama says some models support tools, and they then write the call out as text, which an agent can't run.
 */
export async function toolCallProblem(url: string, model: string, timeoutMs = TOOL_CHECK_TIMEOUT_MS): Promise<string | undefined> {
  let response: Response;
  try {
    response = await fetch(`${url}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(timeoutMs),
      body: JSON.stringify({
        model,
        stream: false,
        temperature: 0,
        messages: [{ role: "user", content: "Create the file a.txt containing hi. Use the write_file tool." }],
        tools: [
          {
            type: "function",
            function: {
              name: "write_file",
              description: "Write a file",
              parameters: {
                type: "object",
                properties: { file_path: { type: "string" }, content: { type: "string" } },
                required: ["file_path", "content"],
              },
            },
          },
        ],
      }),
    });
  } catch (error) {
    if ((error as Error).name === "TimeoutError") return `${model} didn't answer a test request within ${Math.round(timeoutMs / 60_000)} minutes, so it was not added`;
    return `${model} couldn't be tried: ${(error as Error).message}`;
  }
  if (!response.ok) return `${model} refused a test request that uses tools (HTTP ${response.status}), so an agent can't work with it`;
  const body = (await response.json().catch(() => undefined)) as { choices?: { message?: { tool_calls?: unknown[] } }[] } | undefined;
  if (!body?.choices?.[0]?.message?.tool_calls?.length) {
    return `${model} wrote its tool call as plain text instead of making it, so an agent on it couldn't run anything. Choose another model`;
  }
  return undefined;
}

/**
 * Offers agents from the ACP registry and installs them for the service user, without sudo: npm packages and
 * downloads go under the data folder's tools/, downloads only with a checksum the registry publishes, which is checked.
 */
export class AcpRegistry {
  private cached?: { at: number; entries: RegistryEntry[] };
  private readonly installing = new Set<string>();

  readonly toolsDir: string;
  private readonly maxDownloadBytes: number;

  constructor(toolsDir: string, maxDownloadBytes = MAX_DOWNLOAD_BYTES) {
    this.toolsDir = toolsDir;
    this.maxDownloadBytes = maxDownloadBytes;
  }

  /** The registry, at most an hour old; the last copy on disk when it can't be reached. */
  async entries(): Promise<RegistryEntry[]> {
    if (this.cached && Date.now() - this.cached.at < REGISTRY_TTL_MS) return this.cached.entries;
    const source = process.env.KERVAN_ACP_REGISTRY || REGISTRY_URL;
    const copy = join(this.toolsDir, "registry.json");
    let text: string;
    try {
      if (source.startsWith("/")) {
        text = readFileSync(source, "utf8");
      } else {
        const response = await fetch(source, { signal: AbortSignal.timeout(15_000) });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        text = await response.text();
      }
      mkdirSync(this.toolsDir, { recursive: true });
      writeFileSync(copy, text);
    } catch (error) {
      if (!existsSync(copy)) throw new KervanError("bad_message", `couldn't read the agent registry: ${(error as Error).message}`);
      log("warn", "agent registry unreachable; using the saved copy", { error: String(error) });
      text = readFileSync(copy, "utf8");
    }
    const parsed = JSON.parse(text) as { agents?: unknown };
    const entries = (Array.isArray(parsed.agents) ? parsed.agents : []).filter(
      (entry): entry is RegistryEntry =>
        typeof entry === "object" &&
        entry !== null &&
        typeof (entry as RegistryEntry).id === "string" &&
        SAFE_ID.test((entry as RegistryEntry).id) &&
        typeof (entry as RegistryEntry).name === "string",
    );
    this.cached = { at: Date.now(), entries };
    return entries;
  }

  /** Every registry agent and where it stands here. `added` holds the ids of the agents the server already has. */
  async offer(added: Set<string>): Promise<OfferedAgent[]> {
    const tools = await this.tools();
    return (await this.entries())
      .map((entry) => this.describe(entry, added, tools))
      .sort((a, b) => order(a.status) - order(b.status) || a.name.localeCompare(b.name));
  }

  async ollama(): Promise<OllamaStatus> {
    const url = ollamaURL();
    try {
      const response = await fetch(`${url}/api/tags`, { signal: AbortSignal.timeout(2_000) });
      if (!response.ok) return { running: false, url, models: [] };
      const body = (await response.json()) as { models?: { name?: unknown }[] };
      const models = (body.models ?? []).map((m) => m.name).filter((name): name is string => typeof name === "string");
      return { running: true, url, models };
    } catch {
      return { running: false, url, models: [] };
    }
  }

  /** LM Studio's chat models: its list also holds embedding models and its own helpers, which can't run an agent. */
  async lmStudio(): Promise<OllamaStatus> {
    const urls = process.env.LMSTUDIO_URL ? [process.env.LMSTUDIO_URL.replace(/\/+$/, "")] : LM_STUDIO_URLS;
    for (const url of urls) {
      try {
        const response = await fetch(`${url}/api/v0/models`, { signal: AbortSignal.timeout(2_000) });
        if (!response.ok) continue;
        const body = (await response.json()) as { data?: { id?: unknown; type?: unknown; publisher?: unknown }[] };
        const models = (body.data ?? [])
          .filter((m) => (m.type === "llm" || m.type === "vlm") && m.publisher !== "model-extension-pack")
          .map((m) => m.id)
          .filter((id): id is string => typeof id === "string");
        return { running: true, url, models };
      } catch {
        // Not there, or not LM Studio: try the next one.
      }
    }
    return { running: false, url: urls[0]!, models: [] };
  }

  /** Installs (or finds) an agent and says how to start it; saving it in the catalog is the caller's. */
  async install(request: InstallRequest): Promise<InstalledAgent> {
    const entry = (await this.entries()).find((e) => e.id === request.agentId);
    if (!entry) throw new KervanError("bad_message", `no agent '${request.agentId}' in the registry`);
    if (BUILTIN[entry.id]) throw new KervanError("bad_message", `${entry.name} comes with Kervan already`);
    if (this.installing.has(entry.id)) throw new KervanError("bad_message", `${entry.name} is being installed already`);
    this.installing.add(entry.id);
    try {
      let env: Record<string, string> = {};
      let authMethod: string | undefined;
      if (request.ollamaModel && request.lmStudioModel) throw new KervanError("bad_message", "choose one local model");
      const model = request.ollamaModel ?? request.lmStudioModel;
      if (model) {
        const app = request.ollamaModel ? "Ollama" : "LM Studio";
        const setup = (request.ollamaModel ? OLLAMA_SETUP : LM_STUDIO_SETUP)[entry.id];
        if (!setup) throw new KervanError("bad_message", `${entry.name} can't be set up for ${app} from here`);
        const status = await (request.ollamaModel ? this.ollama() : this.lmStudio());
        if (!status.running) throw new KervanError("bad_message", `${app} isn't answering at ${status.url}`);
        if (!status.models.includes(model)) throw new KervanError("bad_message", `${app} has no model '${model}'`);
        // Before installing anything: a model that can't call tools leaves nothing worth having installed.
        const problem = await toolCallProblem(status.url, model);
        if (problem) throw new KervanError("bad_message", problem);
        const settings = setup(status.url, model);
        env = settings.env;
        authMethod = settings.authMethod;
      }
      const launch = await this.place(entry, await this.tools());
      env = { ...(launch.env ?? {}), ...env };
      return {
        id: entry.id,
        name: model ? localModelAgentName(entry.name, model) : entry.name,
        command: launch.command,
        args: launch.args,
        ...(Object.keys(env).length > 0 ? { env } : {}),
        ...(authMethod ? { authMethod } : {}),
      };
    } finally {
      this.installing.delete(entry.id);
    }
  }

  private describe(entry: RegistryEntry, added: Set<string>, tools: { npm: boolean; uvx: boolean }): OfferedAgent {
    const base = {
      id: entry.id,
      name: entry.name,
      description: entry.description ?? "",
      ...(entry.version ? { version: entry.version } : {}),
      ...((entry.website ?? entry.repository) ? { website: entry.website ?? entry.repository } : {}),
      ollama: entry.id in OLLAMA_SETUP,
    };
    const builtin = BUILTIN[entry.id];
    if (builtin) return { ...base, status: added.has(builtin) ? "builtin" : "unavailable", ...(added.has(builtin) ? {} : { reason: "turned off on this server" }) };
    if (added.has(entry.id)) return { ...base, status: "added" };
    const found = findCommand(commandNames(entry));
    if (found) return { ...base, status: "found", path: found };
    const how = this.installMethod(entry, tools);
    return how.source ? { ...base, status: "installable", source: how.source } : { ...base, status: "unavailable", reason: how.reason };
  }

  private installMethod(entry: RegistryEntry, tools: { npm: boolean; uvx: boolean }): { source?: OfferedAgent["source"]; reason?: string } {
    const { npx, uvx, binary } = entry.distribution;
    const download = binary?.[platformKey()];
    if (npx && tools.npm && PINNED_NPM.test(npx.package)) return { source: "npm" };
    if (download?.sha256 && isSecureDownload(download.archive)) return { source: "download" };
    if (uvx && tools.uvx && PINNED_UV.test(uvx.package)) return { source: "uvx" };
    if (download?.sha256) return { reason: "its download isn't over HTTPS" };
    if (download) return { reason: "its download has no published checksum" };
    if (uvx && tools.uvx) return { reason: "its package isn't pinned to a version" };
    if (uvx) return { reason: "needs uv on the server" };
    if (npx && tools.npm) return { reason: "its package isn't pinned to a version" };
    if (npx) return { reason: "needs npm on the server" };
    return { reason: `no build for ${platformKey()}` };
  }

  /** What the server can install with. */
  private async tools(): Promise<{ npm: boolean; uvx: boolean }> {
    return { npm: findCommand(["npm"]) !== undefined, uvx: findCommand(["uvx"]) !== undefined };
  }

  /** Puts the agent where it can run (or finds it already there) and returns how to start it. */
  private async place(entry: RegistryEntry, tools: { npm: boolean; uvx: boolean }): Promise<{ command: string; args: string[]; env?: Record<string, string> }> {
    const { npx, uvx, binary } = entry.distribution;
    const download = binary?.[platformKey()];
    const found = findCommand(commandNames(entry));
    if (found) {
      const launch = npx ?? download ?? uvx;
      return { command: found, args: launch?.args ?? [], ...(launch?.env ? { env: launch.env } : {}) };
    }
    const folder = join(this.toolsDir, entry.id);
    const how = this.installMethod(entry, tools).source;
    if (npx && how === "npm") {
      if (!isPlaced(folder, npx.package, join(folder, "node_modules", packageName(npx.package), "package.json"))) {
        rmSync(folder, { recursive: true, force: true });
        mkdirSync(folder, { recursive: true });
        const npmArgs = ["install", "--prefix", folder, "--no-audit", "--no-fund", "--loglevel=error", npx.package];
        // A package's install scripts run here, so they run as an agent would, and see no more.
        const npmOptions = { env: cleanEnv(["npm_config_*", "NPM_*"]), timeout: 10 * 60_000 };
        await (agentUser() ? runAsAgent("npm", npmArgs, npmOptions) : run("npm", npmArgs, npmOptions)).catch(
          (error: { stderr?: string }) => {
            throw new KervanError("bad_message", `npm couldn't install ${npx.package}: ${error.stderr?.trim().split("\n").pop() || String(error)}`);
          },
        );
        writeFileSync(join(folder, PLACED_FILE), npx.package);
      }
      return { command: npmBinary(folder, npx.package, commandNames(entry)), args: npx.args ?? [], ...(npx.env ? { env: npx.env } : {}) };
    }
    if (download && how === "download") {
      const command = archiveCommand(download, folder);
      if (!isPlaced(folder, download.sha256!, command)) {
        rmSync(folder, { recursive: true, force: true });
        mkdirSync(folder, { recursive: true });
        await fetchArchive(download, folder, this.maxDownloadBytes);
        writeFileSync(join(folder, PLACED_FILE), download.sha256!);
      }
      return { command, args: download.args ?? [], ...(download.env ? { env: download.env } : {}) };
    }
    if (uvx && how === "uvx") {
      return { command: findCommand(["uvx"])!, args: [uvx.package, ...(uvx.args ?? [])], ...(uvx.env ? { env: uvx.env } : {}) };
    }
    throw new KervanError("bad_message", `${entry.name} can't be installed on this server: ${this.installMethod(entry, tools).reason}`);
  }
}

const order = (status: OfferedAgent["status"]) => ["found", "installable", "added", "builtin", "unavailable"].indexOf(status);

// Written once an install has finished, naming what was installed.
const PLACED_FILE = ".kervan-placed";

/**
 * Whether `folder` holds this very release, finished. Another model of an agent reuses its copy: installing again
 * would delete the program agents already added are running from.
 */
function isPlaced(folder: string, source: string, file: string): boolean {
  try {
    return readFileSync(join(folder, PLACED_FILE), "utf8") === source && existsSync(file);
  } catch {
    return false;
  }
}

/** Where a download's program ends up in `folder`. */
function archiveCommand(download: BinaryLaunch, folder: string): string {
  const command = resolve(folder, download.cmd);
  if (command !== folder && !command.startsWith(folder + sep)) throw new KervanError("bad_message", "the registry entry points outside its folder");
  return command;
}

/** The installed package's command: the one named like the agent, else its only (or first) one. */
function npmBinary(folder: string, spec: string, names: string[]): string {
  const name = packageName(spec);
  const manifest = JSON.parse(readFileSync(join(folder, "node_modules", name, "package.json"), "utf8")) as { bin?: string | Record<string, string> };
  const bins = typeof manifest.bin === "string" ? [basename(name)] : Object.keys(manifest.bin ?? {});
  const chosen = names.find((n) => bins.includes(n)) ?? bins[0];
  const path = chosen ? join(folder, "node_modules/.bin", chosen) : undefined;
  if (!path || !existsSync(path)) throw new KervanError("bad_message", `${name} installed, but it has no command to start`);
  return path;
}

/** HTTPS only; plain HTTP just for this machine itself. */
function isSecureDownload(address: string): boolean {
  try {
    const url = new URL(address);
    return url.protocol === "https:" || (url.protocol === "http:" && ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname));
  } catch {
    return false;
  }
}

/** The whole body, giving up as soon as it passes the limit rather than after holding it all in memory. */
async function readLimited(response: Response, maxBytes: number): Promise<Buffer> {
  const tooLarge = () => new KervanError("bad_message", "the download is too large");
  if (Number(response.headers.get("content-length") ?? 0) > maxBytes) throw tooLarge();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > maxBytes) {
      void response.body?.cancel().catch(() => {});
      throw tooLarge();
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** Downloads an archive, checks it against the registry's checksum, unpacks it into `folder` and returns the command. */
async function fetchArchive(download: BinaryLaunch, folder: string, maxBytes: number): Promise<string> {
  const response = await fetch(download.archive, { signal: AbortSignal.timeout(10 * 60_000) });
  if (!response.ok) throw new KervanError("bad_message", `the download failed (HTTP ${response.status})`);
  const data = await readLimited(response, maxBytes);
  const sum = createHash("sha256").update(data).digest("hex");
  if (sum.toLowerCase() !== download.sha256!.toLowerCase()) {
    throw new KervanError("bad_message", "the download doesn't match the checksum the registry publishes; nothing was installed");
  }

  const command = archiveCommand(download, folder);
  const file = new URL(download.archive).pathname;
  if (/\.(tar\.gz|tgz|tar\.bz2|tar\.xz|tar)$/.test(file)) {
    const archive = join(folder, ".download.tar");
    writeFileSync(archive, data);
    await run("tar", ["-xf", archive, "-C", folder], { timeout: 5 * 60_000 });
    rmSync(archive, { force: true });
  } else if (file.endsWith(".zip")) {
    const archive = join(folder, ".download.zip");
    writeFileSync(archive, data);
    await run("unzip", ["-q", "-o", archive, "-d", folder], { timeout: 5 * 60_000 }).catch(() =>
      run("python3", ["-I", "-m", "zipfile", "-e", archive, folder], { timeout: 5 * 60_000 }),
    );
    rmSync(archive, { force: true });
  } else {
    // A bare program, not an archive.
    mkdirSync(dirname(command), { recursive: true });
    writeFileSync(command, data);
  }
  if (!existsSync(command)) throw new KervanError("bad_message", `the download has no ${download.cmd}`);
  chmodSync(command, 0o755);
  return command;
}
