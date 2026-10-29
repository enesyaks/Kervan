import { accessSync, constants, existsSync, readFileSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";
import { isSafeRelativePath } from "./files.ts";
import { log } from "./log.ts";

/** How to start an agent that speaks ACP over stdio. */
export interface AgentCommand {
  command: string;
  args: string[];
  env?: Record<string, string>;
  /** ACP auth method to select right after `initialize`, for agents that wait for one (Gemini). */
  authMethod?: string;
  /** Workspace folder the agent loads Agent Skills from; others get them in `.kervan/skills`. */
  skillsDir?: string;
}

export interface AgentDefinition extends AgentCommand {
  /** Shown in the app, e.g. "Claude Code". */
  name: string;
}

/** Insertion order is the app's order; the first agent is the default. */
export type AgentRegistry = ReadonlyMap<string, AgentDefinition>;

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const bin = (name: string) => join(serverRoot, "node_modules/.bin", name);

/** Adapters shipped in server/package.json; `command: builtin` in agents.yaml refers to these. */
const BUILTIN: Record<string, AgentDefinition> = {
  claude: { name: "Claude Code", command: bin("claude-agent-acp"), args: [], skillsDir: ".claude/skills" },
  codex: { name: "Codex", command: bin("codex-acp"), args: [], skillsDir: ".agents/skills" },
  // Gemini blocks on its first prompt until a method is chosen; Google account login is closed to individuals.
  gemini: { name: "Gemini", command: bin("gemini"), args: ["--acp"], authMethod: "gemini-api-key", skillsDir: ".gemini/skills" },
};

function fail(file: string, message: string): never {
  throw new Error(`${file}: ${message}`);
}

const isStringRecord = (value: unknown): value is Record<string, string> =>
  typeof value === "object" && value !== null && !Array.isArray(value) && Object.values(value).every((v) => typeof v === "string");

/** True if `command` is an executable path, or a bare name found on PATH. */
export function isRunnable(command: string, path = process.env.PATH ?? ""): boolean {
  const candidates = isAbsolute(command) || command.includes("/") ? [command] : path.split(delimiter).map((dir) => join(dir, command));
  return candidates.some((candidate) => {
    try {
      accessSync(candidate, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

/** Parses agents.yaml text. Throws with the file name and the offending agent on bad input. */
export function parseAgents(text: string, file = "agents.yaml"): AgentDefinition[] & { ids: string[] } {
  const doc = parse(text) as unknown;
  const agents = (doc as { agents?: unknown } | null)?.agents;
  if (typeof agents !== "object" || agents === null || Array.isArray(agents)) fail(file, "expected an 'agents:' map");

  const ids: string[] = [];
  const definitions: AgentDefinition[] = [];
  for (const [id, raw] of Object.entries(agents)) {
    if (!/^[a-z][a-z0-9-]{0,31}$/.test(id)) fail(file, `agent id '${id}' must be lowercase letters, digits or '-'`);
    if (typeof raw !== "object" || raw === null) fail(file, `agent '${id}' must be a map`);
    const entry = raw as Record<string, unknown>;

    const builtin = BUILTIN[id];
    if (entry.command === "builtin" && !builtin) fail(file, `agent '${id}' has no builtin adapter`);
    const base = entry.command === "builtin" ? builtin : undefined;

    const command = base?.command ?? entry.command;
    if (typeof command !== "string" || command === "") fail(file, `agent '${id}' needs a 'command'`);
    const args = entry.args ?? base?.args ?? [];
    if (!Array.isArray(args) || !args.every((a) => typeof a === "string")) fail(file, `agent '${id}': 'args' must be a list of strings`);
    if (entry.env !== undefined && !isStringRecord(entry.env)) fail(file, `agent '${id}': 'env' must map names to strings`);
    const name = entry.name ?? base?.name ?? id;
    if (typeof name !== "string") fail(file, `agent '${id}': 'name' must be text`);
    const authMethod = entry.authMethod ?? base?.authMethod;
    if (authMethod !== undefined && typeof authMethod !== "string") fail(file, `agent '${id}': 'authMethod' must be text`);
    const skillsDir = entry.skillsDir ?? base?.skillsDir;
    if (skillsDir !== undefined && (typeof skillsDir !== "string" || !isSafeRelativePath(skillsDir))) {
      fail(file, `agent '${id}': 'skillsDir' must be a path inside the workspace`);
    }

    ids.push(id);
    definitions.push({
      name,
      command,
      args,
      ...(entry.env ? { env: entry.env as Record<string, string> } : {}),
      ...(authMethod ? { authMethod } : {}),
      ...(skillsDir ? { skillsDir: skillsDir as string } : {}),
    });
  }
  return Object.assign(definitions, { ids });
}

/**
 * Agents from `file` (agents.yaml), or the builtin adapters when there is none.
 * Agents whose command can't be run here are left out, so the app only offers what works.
 */
export function loadAgents(file?: string): AgentRegistry {
  const entries: [string, AgentDefinition][] =
    file && existsSync(file)
      ? (() => {
          const parsed = parseAgents(readFileSync(file, "utf8"), file);
          return parsed.ids.map((id, i): [string, AgentDefinition] => [id, parsed[i]]);
        })()
      : Object.entries(BUILTIN);

  const registry = new Map<string, AgentDefinition>();
  for (const [id, definition] of entries) {
    if (isRunnable(definition.command)) registry.set(id, definition);
    else log("warn", "agent not available, skipping", { id, command: definition.command });
  }
  return registry;
}
