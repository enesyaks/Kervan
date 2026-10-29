import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { stringify } from "yaml";
import { type AgentDefinition, type AgentRegistry, isRunnable, parseAgents } from "./agents.ts";
import { KervanError } from "./protocol.ts";

/** An agent added from the app. `node` says where it runs; only this server ("local") until M13. */
export interface ManagedAgent {
  id: string;
  name: string;
  /** A path, a command on PATH, or "builtin" for the adapter shipped with the server. */
  command: string;
  args?: string[];
  authMethod?: string;
  skillsDir?: string;
  env?: Record<string, string>;
  node: string;
}

/** What clients see; env values are reduced to their names. */
export interface AgentSummary {
  id: string;
  name: string;
  command: string;
  args: string[];
  authMethod?: string;
  skillsDir?: string;
  envKeys: string[];
  node: string;
  /** "app" agents can be edited from the app; the others come with the server or agents.yaml. */
  source: "builtin" | "app";
  available: boolean;
}

export const NODES = ["local"];

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/**
 * All agents this server offers: its configured ones (builtin adapters or agents.yaml) plus those
 * added from the app. `live` is the map sessions read; it is updated in place, so changes apply
 * to the next session without a restart.
 */
export class AgentCatalog {
  readonly live = new Map<string, AgentDefinition>();
  private readonly file: string;
  private readonly base: AgentRegistry;
  private readonly probe: (definition: AgentDefinition) => Promise<void>;
  private managed: Map<string, ManagedAgent>;

  constructor(file: string, base: AgentRegistry, probe: (definition: AgentDefinition) => Promise<void>) {
    this.file = file;
    this.base = base;
    this.probe = probe;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as ManagedAgent[]) : [];
    this.managed = new Map(stored.map((agent) => [agent.id, agent]));
    this.rebuild();
  }

  list(): AgentSummary[] {
    const fromServer = [...this.base]
      .filter(([id]) => !this.managed.has(id))
      .map(([id, d]): AgentSummary => ({
        id,
        name: d.name,
        command: d.command,
        args: d.args,
        ...(d.authMethod ? { authMethod: d.authMethod } : {}),
        ...(d.skillsDir ? { skillsDir: d.skillsDir } : {}),
        envKeys: Object.keys(d.env ?? {}),
        node: "local",
        source: "builtin",
        available: true,
      }));
    const fromApp = [...this.managed.values()].map((agent): AgentSummary => ({
      id: agent.id,
      name: agent.name,
      command: agent.command,
      args: agent.args ?? [],
      ...(agent.authMethod ? { authMethod: agent.authMethod } : {}),
      ...(agent.skillsDir ? { skillsDir: agent.skillsDir } : {}),
      envKeys: Object.keys(agent.env ?? {}),
      node: agent.node,
      source: "app",
      available: this.live.has(agent.id),
    }));
    return [...fromServer, ...fromApp];
  }

  /**
   * Validates, then starts the agent once (ACP initialize + a session) before keeping it, so the
   * app never offers an agent that can't start. A `null` env value keeps the stored one.
   */
  async save(input: unknown): Promise<void> {
    if (typeof input !== "object" || input === null || Array.isArray(input)) bad("agent must be an object");
    const raw = input as Record<string, unknown>;
    const id = raw.id;
    if (typeof id !== "string") return bad("agent needs an 'id'");
    const node = raw.node ?? "local";
    if (typeof node !== "string" || !NODES.includes(node)) bad(`node '${String(node)}' is not available; this server has: ${NODES.join(", ")}`);
    const previous = this.managed.get(id);
    const env = mergeEnv(raw.env, previous?.env);

    // Reuse the agents.yaml rules for everything but secrets.
    const { env: _ignored, node: _node, id: _id, ...fields } = raw;
    let definition: AgentDefinition;
    try {
      [definition] = parseAgents(stringify({ agents: { [id]: fields } }), "agent");
    } catch (error) {
      return bad((error as Error).message.replace(/^agent: /, ""));
    }
    if (!isRunnable(definition.command)) bad(`command '${definition.command}' can't be run on this server`);
    const withEnv = { ...definition, ...(env ? { env } : {}) };

    try {
      await this.probe(withEnv);
    } catch (error) {
      bad(`the agent didn't start: ${(error as Error).message}`);
    }

    this.managed.set(id, {
      id,
      name: definition.name,
      command: raw.command as string,
      ...(definition.args.length > 0 || raw.args ? { args: definition.args } : {}),
      ...(definition.authMethod ? { authMethod: definition.authMethod } : {}),
      ...(definition.skillsDir ? { skillsDir: definition.skillsDir } : {}),
      ...(env ? { env } : {}),
      node: node as string,
    });
    this.persist();
    this.rebuild();
  }

  remove(id: string): void {
    if (!this.managed.delete(id)) bad(`'${id}' was not added from the app and can't be removed here`);
    this.persist();
    this.rebuild();
  }

  private rebuild(): void {
    this.live.clear();
    for (const [id, definition] of this.base) this.live.set(id, definition);
    for (const agent of this.managed.values()) {
      const { env, node: _node, id, ...fields } = agent;
      try {
        const [definition] = parseAgents(stringify({ agents: { [id]: fields } }), "agents.json");
        if (isRunnable(definition.command)) this.live.set(id, { ...definition, ...(env ? { env } : {}) });
      } catch {
        // A stored agent that no longer validates is listed as unavailable rather than breaking startup.
      }
    }
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify([...this.managed.values()], null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}

function mergeEnv(input: unknown, previous: Record<string, string> | undefined): Record<string, string> | undefined {
  if (input === undefined) return previous;
  if (typeof input !== "object" || input === null || Array.isArray(input)) return bad("env must map names to values");
  const merged: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key)) bad(`env name '${key}' is not valid`);
    if (value === null) {
      if (previous?.[key] === undefined) bad(`env '${key}' has no stored value to keep`);
      merged[key] = previous![key];
    } else if (typeof value === "string") {
      merged[key] = value;
    } else {
      bad(`env '${key}' must be text`);
    }
  }
  return merged;
}
