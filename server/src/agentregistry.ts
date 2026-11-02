import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { accessSync, chmodSync, constants, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, delimiter, dirname, join, resolve, sep } from "node:path";
import { promisify } from "node:util";
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
  /** It can be set up to use a model from the server's Ollama. */
  ollama: boolean;
}

export interface OllamaStatus {
  running: boolean;
  url: string;
  models: string[];
}

/** What a client asked to add: the agent, and an Ollama model to run it with if it should. */
export interface InstallRequest {
  agentId: string;
  ollamaModel?: string;
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

  /** Installs (or finds) an agent and says how to start it; saving it in the catalog is the caller's. */
  async install(request: InstallRequest): Promise<InstalledAgent> {
    const entry = (await this.entries()).find((e) => e.id === request.agentId);
    if (!entry) throw new KervanError("bad_message", `no agent '${request.agentId}' in the registry`);
    if (BUILTIN[entry.id]) throw new KervanError("bad_message", `${entry.name} comes with Kervan already`);
    if (this.installing.has(entry.id)) throw new KervanError("bad_message", `${entry.name} is being installed already`);
    this.installing.add(entry.id);
    try {
      const tools = await this.tools();
      const launch = await this.place(entry, tools);
      let env = { ...(launch.env ?? {}) };
      let authMethod: string | undefined;
      if (request.ollamaModel) {
        const setup = OLLAMA_SETUP[entry.id];
        if (!setup) throw new KervanError("bad_message", `${entry.name} can't be set up for Ollama from here`);
        const ollama = await this.ollama();
        if (!ollama.running) throw new KervanError("bad_message", `Ollama isn't answering at ${ollama.url}`);
        if (!ollama.models.includes(request.ollamaModel)) throw new KervanError("bad_message", `Ollama has no model '${request.ollamaModel}'`);
        const settings = setup(ollama.url, request.ollamaModel);
        env = { ...env, ...settings.env };
        authMethod = settings.authMethod;
      }
      return {
        id: entry.id,
        name: request.ollamaModel ? `${entry.name} (${request.ollamaModel})` : entry.name,
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
      rmSync(folder, { recursive: true, force: true });
      mkdirSync(folder, { recursive: true });
      await run("npm", ["install", "--prefix", folder, "--no-audit", "--no-fund", "--loglevel=error", npx.package], { timeout: 10 * 60_000 }).catch(
        (error: { stderr?: string }) => {
          throw new KervanError("bad_message", `npm couldn't install ${npx.package}: ${error.stderr?.trim().split("\n").pop() || String(error)}`);
        },
      );
      return { command: npmBinary(folder, npx.package, commandNames(entry)), args: npx.args ?? [], ...(npx.env ? { env: npx.env } : {}) };
    }
    if (download && how === "download") {
      rmSync(folder, { recursive: true, force: true });
      mkdirSync(folder, { recursive: true });
      const command = await fetchArchive(download, folder, this.maxDownloadBytes);
      return { command, args: download.args ?? [], ...(download.env ? { env: download.env } : {}) };
    }
    if (uvx && how === "uvx") {
      return { command: findCommand(["uvx"])!, args: [uvx.package, ...(uvx.args ?? [])], ...(uvx.env ? { env: uvx.env } : {}) };
    }
    throw new KervanError("bad_message", `${entry.name} can't be installed on this server: ${this.installMethod(entry, tools).reason}`);
  }
}

const order = (status: OfferedAgent["status"]) => ["found", "installable", "added", "builtin", "unavailable"].indexOf(status);

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

  const command = resolve(folder, download.cmd);
  if (command !== folder && !command.startsWith(folder + sep)) throw new KervanError("bad_message", "the registry entry points outside its folder");
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
