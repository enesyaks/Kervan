import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import type * as acp from "@agentclientprotocol/sdk";
import { KervanError } from "./protocol.ts";

const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
const KEY = /^[A-Za-z_][A-Za-z0-9_-]{0,127}$/;

export interface McpServerConfig {
  name: string;
  transport: "stdio" | "http";
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
}

/** What clients may see: secret values are reduced to their keys. */
export interface McpServerSummary {
  name: string;
  transport: "stdio" | "http";
  command?: string;
  args?: string[];
  url?: string;
  envKeys: string[];
  headerKeys: string[];
}

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Secret-bearing map from a client: a `null` value keeps the stored one, so the app can edit a server
 * without ever having seen its secrets.
 */
function mergeSecrets(input: unknown, previous: Record<string, string> | undefined, what: string) {
  if (input === undefined) return previous;
  if (!isRecord(input)) return bad(`${what} must map names to values`);
  const merged: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    if (!KEY.test(key)) bad(`${what} name '${key}' is not valid`);
    if (value === null) {
      if (previous?.[key] === undefined) bad(`${what} '${key}' has no stored value to keep`);
      merged[key] = previous![key];
    } else if (typeof value === "string") {
      merged[key] = value;
    } else {
      bad(`${what} '${key}' must be text`);
    }
  }
  return merged;
}

/** MCP servers the user registered, stored in a file only the service user can read. */
export class McpRegistry {
  private readonly file: string;
  private servers: Map<string, McpServerConfig>;

  constructor(file: string) {
    this.file = file;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as McpServerConfig[]) : [];
    this.servers = new Map(stored.map((server) => [server.name, server]));
  }

  has(name: string): boolean {
    return this.servers.has(name);
  }

  list(): McpServerSummary[] {
    return [...this.servers.values()]
      .map(({ name, transport, command, args, url, env, headers }) => ({
        name,
        transport,
        ...(command ? { command } : {}),
        ...(args ? { args } : {}),
        ...(url ? { url } : {}),
        envKeys: Object.keys(env ?? {}),
        headerKeys: Object.keys(headers ?? {}),
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  save(input: unknown): McpServerSummary {
    if (!isRecord(input)) bad("server must be an object");
    const { name, transport } = input as Record<string, unknown>;
    if (typeof name !== "string" || !NAME.test(name)) bad("name must be lowercase letters, digits or '-'");
    if (name === "kervan") bad("'kervan' is reserved for Kervan's own tools");
    const previous = this.servers.get(name as string);

    let server: McpServerConfig;
    if (transport === "stdio") {
      const { command, args } = input as Record<string, unknown>;
      if (typeof command !== "string" || command.trim() === "") bad("a stdio server needs a command");
      if (args !== undefined && (!Array.isArray(args) || !args.every((a) => typeof a === "string"))) bad("args must be a list of text");
      const env = mergeSecrets((input as Record<string, unknown>).env, previous?.env, "env");
      server = { name: name as string, transport, command: command as string, args: (args as string[]) ?? [], ...(env ? { env } : {}) };
    } else if (transport === "http") {
      const { url } = input as Record<string, unknown>;
      if (typeof url !== "string" || !/^https?:\/\/\S+$/.test(url)) bad("an http server needs an http(s) url");
      const headers = mergeSecrets((input as Record<string, unknown>).headers, previous?.headers, "header");
      server = { name: name as string, transport, url: url as string, ...(headers ? { headers } : {}) };
    } else {
      return bad("transport must be 'stdio' or 'http'");
    }

    this.servers.set(server.name, server);
    this.persist();
    return this.list().find((s) => s.name === server.name)!;
  }

  remove(name: string): void {
    if (!this.servers.delete(name)) bad(`no MCP server named '${name}'`);
    this.persist();
  }

  /** ACP form of the named servers. HTTP ones are left out (and reported) when the agent can't use them. */
  toAcp(names: string[], supportsHttp: boolean): { servers: acp.McpServer[]; skipped: string[] } {
    const servers: acp.McpServer[] = [];
    const skipped: string[] = [];
    for (const name of names) {
      const server = this.servers.get(name);
      if (!server) continue;
      if (server.transport === "http") {
        if (!supportsHttp) {
          skipped.push(name);
          continue;
        }
        servers.push({
          type: "http",
          name,
          url: server.url!,
          headers: Object.entries(server.headers ?? {}).map(([key, value]) => ({ name: key, value })),
        });
      } else {
        servers.push({
          name,
          command: server.command!,
          args: server.args ?? [],
          env: Object.entries(server.env ?? {}).map(([key, value]) => ({ name: key, value })),
        });
      }
    }
    return { servers, skipped };
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify([...this.servers.values()], null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}
