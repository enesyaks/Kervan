import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname, networkInterfaces } from "node:os";
import { isAbsolute } from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import type { WebSocket } from "ws";
import type { AgentCommand } from "./agents.ts";
import type { FileEntry } from "./files.ts";
import { log } from "./log.ts";
import { KervanError, type ConfigOption, type SessionEventBody } from "./protocol.ts";
import { Rpc } from "./rpc.ts";
import type { AgentProcess, AgentRunner, PermissionDecision, PermissionRequest, StartOptions } from "./runner.ts";

export const LOCAL_NODE = "local";
export const NODE_NAME = /^[a-z0-9][a-z0-9-]{0,31}$/;
/** How long an invite to add a node stays usable. */
export const INVITE_MINUTES = 30;

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");

/** An address of this hub a new node could use; LAN ones carry their network for a firewall rule. */
export interface HubAddress {
  address: string;
  kind: "tailscale" | "lan";
  /** e.g. 192.168.1.0/24 */
  network?: string;
}

/** This machine's IPv4 addresses that other machines might reach: Tailscale's, then private LAN ones. */
export function hubAddresses(port: number, interfaces = networkInterfaces()): HubAddress[] {
  const found: HubAddress[] = [];
  for (const [name, entries] of Object.entries(interfaces)) {
    // Container bridges are reachable only from this machine.
    if (/^(docker|br-|veth|virbr|lo)/.test(name)) continue;
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      const [a, b] = entry.address.split(".").map(Number);
      const tailscale = name.startsWith("tailscale") || (a === 100 && b >= 64 && b <= 127);
      const lan = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
      if (tailscale) found.push({ address: `${entry.address}:${port}`, kind: "tailscale" });
      else if (lan) found.push({ address: `${entry.address}:${port}`, kind: "lan", ...(entry.cidr ? { network: networkOf(entry.cidr) } : {}) });
    }
  }
  return found.sort((x, y) => (x.kind === y.kind ? 0 : x.kind === "tailscale" ? -1 : 1));
}

function networkOf(cidr: string): string {
  const [ip, bits] = cidr.split("/");
  const mask = Number(bits) === 0 ? 0 : (~0 << (32 - Number(bits))) >>> 0;
  const value = ip.split(".").reduce((n, part) => ((n << 8) | Number(part)) >>> 0, 0) & mask;
  return `${[24, 16, 8, 0].map((shift) => (value >>> shift) & 255).join(".")}/${bits}`;
}

/** A node as stored: its own token is kept only as a hash. */
interface StoredNode extends NodeInfo {
  tokenHash?: string;
}

export interface NodeInfo {
  name: string;
  connected: boolean;
  version?: string;
  /** ISO time the node last connected or disconnected. */
  lastSeen?: string;
  /** host:port the node last reached this hub at; if the hub no longer has it, the node may be lost. */
  via?: string;
}

interface RemoteProcess {
  options: StartOptions;
  markExited: () => void;
}

interface Connection {
  rpc: Rpc;
  ws: WebSocket;
  processes: Map<string, RemoteProcess>;
}

/**
 * The hub's side of the nodes: other machines running `kervan-node`, connected over WebSocket.
 * Nodes that ever connected are remembered in `nodes.json`, so agents assigned to one stay listed while
 * it is offline; starting such an agent then fails with a clear message.
 */
export class NodeHub {
  private readonly file: string;
  private readonly known = new Map<string, StoredNode>();
  /** Single-use invite codes for adding a node, with the name it will get and when the code expires. */
  private readonly invites = new Map<string, { name: string; expires: number }>();
  private readonly connections = new Map<string, Connection>();
  private readonly onChange: () => void;
  /** The port this hub listens on, for the addresses it suggests to new nodes. */
  port = 7420;

  constructor(file: string, onChange: () => void = () => {}) {
    this.file = file;
    this.onChange = onChange;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as StoredNode[]) : [];
    for (const node of stored) this.known.set(node.name, { ...node, connected: false });
  }

  /** Every node an agent can be assigned to: this server first, then the remembered ones. */
  names(): string[] {
    return [LOCAL_NODE, ...[...this.known.keys()].sort()];
  }

  /** Where a new node could reach this hub. */
  addresses(): HubAddress[] {
    return hubAddresses(this.port);
  }

  /**
   * Every ws:// address a node could use for this hub, `first` (what it used just now) first, then the
   * Tailscale and LAN IPs and the mDNS name (<host>.local, answered when avahi runs here). Nodes keep this
   * list, so when the hub's IP changes they still find it by one of the others.
   */
  hubUrls(first?: string): string[] {
    const hosts = [
      ...(first ? [first] : []),
      ...this.addresses().map((a) => a.address),
      `${hostname().split(".")[0].toLowerCase()}.local:${this.port}`,
    ];
    return [...new Set(hosts.map((host) => `ws://${host}`))];
  }

  isConnected(name: string): boolean {
    return this.connections.has(name);
  }

  list(): NodeInfo[] {
    return [...this.known.values()]
      .map(({ tokenHash: _secret, ...node }) => node)
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  /** True when `token` is the one this node got when it joined. */
  authorize(name: string, token: string): boolean {
    const hash = this.known.get(name)?.tokenHash;
    return hash !== undefined && timingSafeEqual(Buffer.from(hash), Buffer.from(sha256(token)));
  }

  /**
   * A code for adding a node named `name`: the install script carries it, and the node trades it once
   * for a token of its own. Inviting a known name again gives that node a new token when it joins.
   */
  invite(name: string, now = Date.now()): { code: string; expiresAt: string } {
    if (!NODE_NAME.test(name) || name === LOCAL_NODE) {
      throw new KervanError("bad_message", "a node name is lowercase letters, digits or '-', and not 'local'");
    }
    for (const [code, invite] of this.invites) if (invite.expires < now) this.invites.delete(code);
    const code = randomBytes(18).toString("base64url");
    const expires = now + INVITE_MINUTES * 60_000;
    this.invites.set(code, { name, expires });
    return { code, expiresAt: new Date(expires).toISOString() };
  }

  /** The name an unused, unexpired invite is for; throws otherwise. Doesn't use the code up. */
  invited(code: string, now = Date.now()): string {
    const invite = this.invites.get(code);
    if (!invite || invite.expires < now) throw new KervanError("bad_message", "this invite is unknown or has expired; create a new one in the app");
    return invite.name;
  }

  /** Uses the invite up and gives the node its token. */
  join(code: string, now = Date.now()): { name: string; token: string } {
    const name = this.invited(code, now);
    this.invites.delete(code);
    const token = randomBytes(32).toString("hex");
    const previous = this.known.get(name);
    this.remember({ ...(previous ?? { name }), connected: this.connections.has(name), tokenHash: sha256(token) });
    log("info", "node joined", { node: name });
    return { name, token };
  }

  /** Forgets a node: its token stops working and it is disconnected. Agents assigned to it stay, unavailable. */
  remove(name: string): void {
    if (!this.known.delete(name)) throw new KervanError("bad_message", `no node named '${name}'`);
    this.connections.get(name)?.ws.terminate();
    this.connections.delete(name);
    this.persist();
    this.onChange();
  }

  /** A node connected (its token already checked by the upgrade handler). A second connection replaces the first. */
  accept(name: string, ws: WebSocket, via?: string): void {
    this.connections.get(name)?.ws.terminate();
    const rpc = new Rpc(ws);
    const connection: Connection = { rpc, ws, processes: new Map() };
    this.connections.set(name, connection);

    const find = (processId: string) => connection.processes.get(processId);
    rpc
      .on("hello", (params: { version?: string }) => {
        this.remember({
          ...this.known.get(name),
          name,
          connected: true,
          ...(params.version ? { version: params.version } : {}),
          ...(via ? { via } : {}),
          lastSeen: new Date().toISOString(),
        });
        log("info", "node connected", { node: name, version: params.version, via });
        return { hubs: this.hubUrls(via) };
      })
      .on("event", (params: { processId: string; event: SessionEventBody }) => find(params.processId)?.options.onEvent(params.event))
      .on("usage", (params: { processId: string; usage: { used: number; size: number; costUsd?: number } }) =>
        find(params.processId)?.options.onUsage?.(params.usage),
      )
      .on("config", (params: { processId: string; options: ConfigOption[] }) => find(params.processId)?.options.onConfig?.(params.options))
      .on("exited", (params: { processId: string }) => {
        find(params.processId)?.markExited();
        connection.processes.delete(params.processId);
      })
      .on("permission", (params: { processId: string; request: PermissionRequest }): Promise<PermissionDecision> | null =>
        find(params.processId)?.options.onPermission(params.request) ?? null,
      );

    ws.on("close", () => {
      if (this.connections.get(name) !== connection) return;
      this.connections.delete(name);
      // Its agents are gone with the connection; sessions treat this like a crash and resume later.
      for (const process of connection.processes.values()) process.markExited();
      connection.processes.clear();
      const known = this.known.get(name);
      if (known) this.remember({ ...known, connected: false, lastSeen: new Date().toISOString() }); // a removed node stays gone
      log("warn", "node disconnected", { node: name });
    });
  }

  close(): void {
    for (const { ws } of this.connections.values()) ws.terminate();
    this.connections.clear();
  }

  /** Runs agents assigned to a node there, everything else with `local`. */
  runner(local: AgentRunner): AgentRunner {
    return {
      start: (options) => {
        const node = options.command.node;
        return node && node !== LOCAL_NODE ? this.startRemote(node, options) : local.start(options);
      },
    };
  }

  async listFiles(node: string, key: string): Promise<{ entries: FileEntry[]; truncated: boolean }> {
    return this.require(node).rpc.call("files.list", { key });
  }

  async readFile(node: string, key: string, path: string): Promise<Buffer> {
    const { data } = await this.require(node).rpc.call<{ data: string }>("files.read", { key, path });
    return Buffer.from(data, "base64");
  }

  async writeFile(node: string, key: string, path: string, data: Buffer): Promise<number> {
    const { size } = await this.require(node).rpc.call<{ size: number }>("files.write", { key, path, data: data.toString("base64") });
    return size;
  }

  private require(node: string): Connection {
    const connection = this.connections.get(node);
    if (!connection) {
      throw new KervanError("node_offline", this.known.has(node) ? `node '${node}' is offline` : `no node named '${node}'`);
    }
    return connection;
  }

  private async startRemote(node: string, options: StartOptions): Promise<AgentProcess> {
    const { rpc, processes } = this.require(node);
    const processId = randomUUID();
    let markExited!: () => void;
    const exited = new Promise<void>((resolve) => (markExited = resolve));
    processes.set(processId, { options, markExited });

    // Servers are filtered on the node, which learns what its agent supports; ask for all of them here.
    const mcpServers: acp.McpServer[] = options.mcpServers?.(true) ?? [];
    let started: { sessionId: string; canConfigure: boolean };
    try {
      started = await rpc.call("start", {
        processId,
        command: options.command,
        // Sessions pass a workspace key; a trial run before saving an agent passes a folder of this
        // server's, which means nothing on the node, so it gets a throwaway one there.
        key: isAbsolute(options.cwd) ? `.kervan-probe/${processId}` : options.cwd,
        ...(options.resumeSessionId ? { resumeSessionId: options.resumeSessionId } : {}),
        mcpServers,
      });
    } catch (error) {
      processes.delete(processId);
      throw error;
    }

    return {
      sessionId: started.sessionId,
      exited,
      close: () => {
        void rpc.call("close", { processId }).catch(() => {});
        processes.delete(processId);
        markExited();
      },
      prompt: async (text, files = [], preface) => {
        const { stopReason } = await rpc.call<{ stopReason: string }>("prompt", { processId, text, files, ...(preface ? { preface } : {}) });
        return stopReason;
      },
      cancel: async () => {
        await rpc.call("cancel", { processId });
      },
      ...(started.canConfigure
        ? { setConfig: (configId: string, value: string) => rpc.call<ConfigOption[]>("setConfig", { processId, configId, value }) }
        : {}),
    };
  }

  private remember(node: StoredNode): void {
    this.known.set(node.name, node);
    this.persist();
    this.onChange();
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    const stored = [...this.known.values()].map(({ connected: _c, ...rest }) => rest);
    writeFileSync(temp, JSON.stringify(stored, null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}

/** Where an agent runs: the node named in its definition, else this server. */
export const nodeOf = (command: AgentCommand | undefined): string => command?.node ?? LOCAL_NODE;
