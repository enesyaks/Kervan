import { tailnetOnly } from "./tailnet.ts";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { open, rm } from "node:fs/promises";
import { hostname, networkInterfaces } from "node:os";
import { isAbsolute } from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import type { WebSocket } from "ws";
import type { AgentCommand } from "./agents.ts";
import type { InstalledAgent, InstallRequest, OfferedAgent, OllamaStatus } from "./agentregistry.ts";
import type { FileEntry } from "./files.ts";
import { log } from "./log.ts";
import { MAX_REPO_BYTES, REPO_CHUNK_BYTES, appendPiece, megabytes, type Committed } from "./projectcopy.ts";
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
  /** Tailscale only: this machine's MagicDNS name, e.g. kervan.tail1234.ts.net, when known. */
  host?: string;
}

/** This machine's IPv4 addresses that other machines might reach: Tailscale's, then private LAN ones. */
export function hubAddresses(port: number, interfaces = networkInterfaces(), tailscaleHost?: string): HubAddress[] {
  const found: HubAddress[] = [];
  for (const [name, entries] of Object.entries(interfaces)) {
    // Container bridges are reachable only from this machine.
    if (/^(docker|br-|veth|virbr|lo)/.test(name)) continue;
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      const [a, b] = entry.address.split(".").map(Number);
      const tailscale = name.startsWith("tailscale") || (a === 100 && b >= 64 && b <= 127);
      const lan = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
      if (tailscale) found.push({ address: `${entry.address}:${port}`, kind: "tailscale", ...(tailscaleHost ? { host: tailscaleHost } : {}) });
      else if (lan) found.push({ address: `${entry.address}:${port}`, kind: "lan", ...(entry.cidr ? { network: networkOf(entry.cidr) } : {}) });
    }
  }
  return found.sort((x, y) => (x.kind === y.kind ? 0 : x.kind === "tailscale" ? -1 : 1));
}

const TAILSCALE_CLI = ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"];
const TAILSCALE_NAME_TTL_MS = 5 * 60_000;
let tailscaleNameCache: { name: string | undefined; at: number } | undefined;

/** The MagicDNS name `tailscale status` reports for this machine, without the trailing dot; cached for a while. */
export function tailscaleName(now = Date.now()): string | undefined {
  if (tailscaleNameCache && now - tailscaleNameCache.at < TAILSCALE_NAME_TTL_MS) return tailscaleNameCache.name;
  let name: string | undefined;
  for (const command of TAILSCALE_CLI) {
    try {
      const out = execFileSync(command, ["status", "--json", "--self=true", "--peers=false"], { timeout: 1500, stdio: ["ignore", "pipe", "ignore"] });
      const dns = (JSON.parse(out.toString("utf8")) as { Self?: { DNSName?: string } }).Self?.DNSName;
      name = dns ? dns.replace(/\.$/, "") || undefined : undefined;
      break;
    } catch {
      // Not installed here, not running or not signed in: no name.
    }
  }
  tailscaleNameCache = { name, at: now };
  return name;
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
  /** What the node said it can do in its last hello (e.g. "projects"); kept while it is away. */
  features?: string[];
}

interface RemoteProcess {
  options: StartOptions;
  markExited: () => void;
}

interface Connection {
  rpc: Rpc;
  ws: WebSocket;
  processes: Map<string, RemoteProcess>;
  /** What this node says it can do, from its hello; a version number wouldn't say which build it is. */
  features: Set<string>;
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
  /** Whether a connected node told us in its hello that it can do this. */
  can(node: string, feature: string): boolean {
    return this.connections.get(node)?.features.has(feature) ?? false;
  }

  /** The same, for a node that may be away: what it said the last time it was here. For checks made while saving a card. */
  supports(node: string, feature: string): boolean {
    const connection = this.connections.get(node);
    return connection ? connection.features.has(feature) : (this.known.get(node)?.features?.includes(feature) ?? false);
  }

  /** Set by main.ts: what answers a node's agents when they call the orchestration tools. */
  orchestra?: { answer(token: string, route: string, body?: unknown): Promise<{ status: number; body: unknown }> };
  private lastAddresses = "";
  private addressTimer?: ReturnType<typeof setInterval>;

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
    // Addresses this server wouldn't answer on aren't worth offering.
    const found = hubAddresses(this.port).filter((address) => !tailnetOnly() || address.kind === "tailscale");
    // Asking the tailscale CLI only makes sense when this machine is on a tailnet.
    if (!found.some((a) => a.kind === "tailscale")) return found;
    const host = tailscaleName();
    return host ? found.map((a) => (a.kind === "tailscale" ? { ...a, host } : a)) : found;
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
    const connection: Connection = { rpc, ws, processes: new Map(), features: new Set() };
    this.connections.set(name, connection);

    const find = (processId: string) => connection.processes.get(processId);
    rpc
      .on("hello", (params: { version?: string; features?: string[] }) => {
        connection.features = new Set(Array.isArray(params.features) ? params.features : []);
        this.remember({
          ...this.known.get(name),
          name,
          connected: true,
          ...(params.version ? { version: params.version } : {}),
          ...(via ? { via } : {}),
          features: [...connection.features].sort(),
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
      )
      // A lead on a node reaches the orchestration tools through the connection it already has, so the
      // hub keeps answering on a Unix socket only its own user can open.
      .on("orchestra", async (params: { token?: string; route?: string; body?: unknown }) => {
        if (!this.orchestra) return { status: 503, body: { error: "orchestra_off" } };
        return this.orchestra.answer(String(params.token ?? ""), String(params.route ?? ""), params.body);
      });

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
    if (this.addressTimer) clearInterval(this.addressTimer);
    for (const { ws } of this.connections.values()) ws.terminate();
    this.connections.clear();
  }

  /**
   * Tells clients when this machine's addresses change, e.g. Tailscale signing in after Kervan has started (setup
   * restarts Kervan before the Tailscale sign-in), so the app shows the new address without reconnecting.
   */
  watchAddresses(everyMs = 15_000): void {
    this.addressesChanged();
    this.addressTimer = setInterval(() => {
      if (this.addressesChanged()) this.onChange();
    }, everyMs);
    this.addressTimer.unref();
  }

  /** Whether the addresses differ from the last look. */
  addressesChanged(interfaces = networkInterfaces()): boolean {
    const now = JSON.stringify(hubAddresses(this.port, interfaces));
    const changed = now !== this.lastAddresses;
    this.lastAddresses = now;
    return changed;
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

  /** The commit the session's project copy on the node is on; undefined when it has none yet. */
  async copyHead(node: string, key: string): Promise<string | undefined> {
    const { head } = await this.ask<{ head: string | null }>(node, "repo.status", { key });
    return head ?? undefined;
  }

  /**
   * Gives the node a copy of a project: the bundle at `file` goes over in pieces (one frame each, well under the frame
   * cap), then the node clones it into the session's workspace on `branch`. Returns the commit the copy is on.
   */
  async sendCopy(node: string, key: string, branch: string, file: string): Promise<string> {
    const { rpc } = this.require(node);
    const id = randomUUID();
    const handle = await open(file, "r");
    try {
      const { size } = await handle.stat();
      if (size > MAX_REPO_BYTES) {
        throw new KervanError("bad_message", `the project's history is ${megabytes(size)}; a copy for a node can be at most ${megabytes(MAX_REPO_BYTES)}`);
      }
      const buffer = Buffer.alloc(REPO_CHUNK_BYTES);
      for (let offset = 0; offset < size; ) {
        const { bytesRead } = await handle.read(buffer, 0, REPO_CHUNK_BYTES, offset);
        if (bytesRead === 0) break;
        await rpc.call("blob.put", { id, offset, data: buffer.subarray(0, bytesRead).toString("base64") });
        offset += bytesRead;
      }
      const { head } = await rpc.call<{ head: string }>("repo.clone", { key, branch, id });
      return head;
    } catch (error) {
      void rpc.call("blob.drop", { id }).catch(() => {});
      throw error;
    } finally {
      await handle.close();
    }
  }

  /**
   * Has the node commit what its agent changed on `branch` and, if the branch moved past `base` (what this hub has),
   * reads the new commits back into `file` as a bundle. Returns the node's new tip, or undefined when nothing changed.
   * If the node goes away midway the call fails and `file` is incomplete: the caller drops it.
   */
  async collectTurn(node: string, key: string, branch: string, base: string | undefined, message: string, file: string): Promise<string | undefined> {
    const { rpc } = this.require(node);
    const id = randomUUID();
    try {
      const result = await rpc.call<Committed>("repo.commit", { key, branch, ...(base ? { base } : {}), message, id });
      if (!result.changed) return undefined;
      if (result.size > MAX_REPO_BYTES) throw new Error(`this turn's work is ${megabytes(result.size)}; at most ${megabytes(MAX_REPO_BYTES)} can come at once`);
      await rm(file, { force: true });
      for (let offset = 0; offset < result.size; ) {
        const { data } = await rpc.call<{ data: string }>("blob.get", { id, offset, length: REPO_CHUNK_BYTES });
        const piece = Buffer.from(data, "base64");
        if (piece.length === 0) throw new Error("the node's bundle ended early");
        offset = await appendPiece(file, offset, piece);
      }
      return result.head;
    } finally {
      void rpc.call("blob.drop", { id }).catch(() => {});
    }
  }

  /** What the catalog offers on this node, and its own local models. An error there is an answer, not the hub's failure. */
  async offerAgents(node: string, added: string[]): Promise<{ agents: OfferedAgent[]; ollama: OllamaStatus; lmStudio?: OllamaStatus }> {
    return this.ask(node, "registry.offer", { added });
  }

  /** Installs a catalog agent on the node, set up for that machine; the hub only keeps how to start it. */
  async installAgent(node: string, request: InstallRequest): Promise<InstalledAgent> {
    return this.ask(node, "registry.install", request);
  }

  private async ask<T>(node: string, method: string, params: unknown): Promise<T> {
    const { rpc } = this.require(node);
    try {
      return await rpc.call<T>(method, params);
    } catch (error) {
      throw new KervanError("bad_message", `on node '${node}': ${error instanceof Error ? error.message : String(error)}`);
    }
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
