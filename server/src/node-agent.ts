import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import WebSocket from "ws";
import { AcpRegistry, type InstallRequest } from "./agentregistry.ts";
import type { AgentDefinition } from "./agents.ts";
import { isSafeRelativePath, listTree, resolveInside } from "./files.ts";
import { log } from "./log.ts";
import { Rpc } from "./rpc.ts";
import type { AgentProcess, AgentRunner } from "./runner.ts";
import { VERSION } from "./version.ts";

export const NODE_PATH = "/v1/node";
/** Files moved between hub and node travel inside one WebSocket message. */
export const MAX_NODE_FILE_BYTES = 50 * 1024 * 1024;
export const MAX_NODE_FRAME_BYTES = Math.ceil((MAX_NODE_FILE_BYTES * 4) / 3) + 64 * 1024;

export interface NodeAgentOptions {
  /** Where the catalog's agents come from; tests pass their own. */
  registry?: Pick<AcpRegistry, "offer" | "ollama" | "lmStudio" | "install">;
  /** ws(s)://hub:7420 — the hub's addresses, tried in turn; the path is added. */
  hubUrls: string[];
  /** Where addresses the hub tells us about are kept, so a hub whose IP changed is still found. */
  stateFile?: string;
  token: string;
  name: string;
  workspacesDir: string;
  runner: AgentRunner;
}

/**
 * The node side: connects out to the hub (so the node needs no open port), runs the agents the hub
 * asks for in its own workspaces folder, and reports their events back. Workspaces are named by the
 * hub with a relative key (the session or team id); the node never touches anything outside its folder.
 * If the connection drops, its agents are stopped (the hub resumes them on the next message) and it
 * reconnects with a growing pause.
 */
export class NodeAgent {
  private readonly options: NodeAgentOptions;
  private readonly processes = new Map<string, AgentProcess>();
  private ws?: WebSocket;
  private stopped = false;
  private retry?: NodeJS.Timeout;
  private readonly registry: Pick<AcpRegistry, "offer" | "ollama" | "lmStudio" | "install">;
  private retryMs = 1000;
  /** Every address we know for the hub, the one that last worked first. */
  private hubs: string[];
  private next = 0;

  constructor(options: NodeAgentOptions) {
    this.options = options;
    // In the node user's home: the only place it can be sure to write, on Linux and on a Mac.
    this.registry = options.registry ?? new AcpRegistry(join(homedir(), ".kervan", "tools"));
    const remembered = options.stateFile && existsSync(options.stateFile)
      ? ((JSON.parse(readFileSync(options.stateFile, "utf8")) as { hubs?: string[] }).hubs ?? [])
      : [];
    this.hubs = unique([...remembered, ...options.hubUrls]);
  }

  /** The addresses this node will try, in order (for logs and tests). */
  get knownHubs(): string[] {
    return [...this.hubs];
  }

  start(): void {
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.retry);
    this.ws?.close();
    this.closeAll();
  }

  private connect(): void {
    const { token, name } = this.options;
    const hubUrl = this.hubs[this.next % this.hubs.length];
    let opened = false;
    const ws = new WebSocket(new URL(NODE_PATH, hubUrl), {
      headers: { authorization: `Bearer ${token}`, "x-kervan-node": name },
      maxPayload: MAX_NODE_FRAME_BYTES,
    });
    this.ws = ws;
    const rpc = new Rpc(ws);
    this.serve(rpc);

    ws.on("open", () => {
      opened = true;
      this.retryMs = 1000;
      log("info", "connected to hub", { hub: hubUrl, node: name });
      void rpc
        .call<{ hubs?: string[] } | null>("hello", { version: VERSION })
        .then((answer) => this.learn(hubUrl, answer?.hubs ?? []))
        .catch(() => {});
    });
    ws.on("unexpected-response", (_req, res) => log("error", "hub refused the node", { status: res.statusCode }));
    ws.on("error", (error) => log("warn", "hub connection error", { error: error.message }));
    ws.on("close", () => {
      this.closeAll();
      if (this.stopped) return;
      // A connection that worked is tried again first; an address that never answered gives way to the next.
      // The pause grows only once every address has been tried.
      if (!opened) this.next += 1;
      const wrapped = !opened && this.next % this.hubs.length === 0;
      const delay = opened || wrapped ? this.retryMs : 500;
      log("info", "hub connection closed; retrying", { inMs: delay, next: this.hubs[this.next % this.hubs.length] });
      // Not unref'd: while the hub is away this timer is all that keeps a node's process alive.
      this.retry = setTimeout(() => this.connect(), delay);
      if (opened || wrapped) this.retryMs = Math.min(this.retryMs * 2, 30_000);
    });
  }

  /** Keeps the address that worked first, then everything the hub says it can be reached at, on disk. */
  private learn(worked: string, fromHub: string[]): void {
    this.hubs = unique([worked, ...fromHub, ...this.hubs]);
    this.next = 0;
    const file = this.options.stateFile;
    if (!file) return;
    try {
      writeFileSync(`${file}.tmp`, JSON.stringify({ hubs: this.hubs }, null, 2), { mode: 0o600 });
      renameSync(`${file}.tmp`, file);
    } catch (error) {
      log("warn", "couldn't save the hub's addresses", { error: String(error) });
    }
  }

  private closeAll(): void {
    for (const process of this.processes.values()) process.close();
    this.processes.clear();
  }

  private async workspace(key: string): Promise<string> {
    // Setup on Linux makes the folder; a node started any other way may not have it yet.
    await mkdir(this.options.workspacesDir, { recursive: true });
    const dir = await resolveInside(this.options.workspacesDir, key);
    await mkdir(dir, { recursive: true });
    return dir;
  }

  private process(processId: string): AgentProcess {
    const process = this.processes.get(processId);
    if (!process) throw new Error("that agent is no longer running on this node");
    return process;
  }

  private serve(rpc: Rpc): void {
    const root = this.options.workspacesDir;
    rpc
      .on("start", async (params: { processId: string; command: AgentDefinition; key: string; resumeSessionId?: string; mcpServers: acp.McpServer[] }) => {
        const { processId } = params;
        const cwd = await this.workspace(params.key);
        const process = await this.options.runner.start({
          command: params.command,
          cwd,
          ...(params.resumeSessionId ? { resumeSessionId: params.resumeSessionId } : {}),
          onEvent: (event) => rpc.notify("event", { processId, event }),
          onPermission: (request) => rpc.call("permission", { processId, request }),
          onUsage: (usage) => rpc.notify("usage", { processId, usage }),
          onConfig: (options) => rpc.notify("config", { processId, options }),
          mcpServers: (supportsHttp) => {
            const skipped = params.mcpServers.filter((s) => "type" in s && s.type === "http" && !supportsHttp);
            if (skipped.length > 0) {
              rpc.notify("event", {
                processId,
                event: { kind: "notice", text: `This agent doesn't support HTTP MCP servers; skipped: ${skipped.map((s) => s.name).join(", ")}` },
              });
            }
            return params.mcpServers.filter((s) => !skipped.includes(s));
          },
        });
        this.processes.set(processId, process);
        process.exited.then(() => {
          if (this.processes.get(processId) !== process) return;
          this.processes.delete(processId);
          rpc.notify("exited", { processId });
        });
        return { sessionId: process.sessionId, canConfigure: process.setConfig !== undefined };
      })
      .on("prompt", async (params: { processId: string; text: string; files: string[]; preface?: string }) => {
        const files = await Promise.all(params.files.map((file) => resolveInside(root, file)));
        return { stopReason: await this.process(params.processId).prompt(params.text, files, params.preface) };
      })
      .on("cancel", (params: { processId: string }) => this.processes.get(params.processId)?.cancel())
      .on("close", (params: { processId: string }) => {
        this.processes.get(params.processId)?.close();
        this.processes.delete(params.processId);
      })
      .on("setConfig", (params: { processId: string; configId: string; value: string }) => {
        const process = this.process(params.processId);
        if (!process.setConfig) throw new Error("this agent has no settings");
        return process.setConfig(params.configId, params.value);
      })
      // The catalog as this machine sees it: the agents it has and can install, and its own local models.
      .on("registry.offer", async (params: { added: string[] }) => {
        const [agents, ollama, lmStudio] = await Promise.all([this.registry.offer(new Set(params.added)), this.registry.ollama(), this.registry.lmStudio()]);
        return { agents, ollama, lmStudio };
      })
      .on("registry.install", (params: InstallRequest) => this.registry.install(params))
      .on("files.list", async (params: { key: string }) => listTree(await this.workspace(params.key)))
      .on("files.read", async (params: { key: string; path: string }) => {
        const file = await resolveInside(await this.workspace(params.key), params.path);
        const data = await readFile(file);
        if (data.length > MAX_NODE_FILE_BYTES) throw new Error(`files on a node can be downloaded up to ${MAX_NODE_FILE_BYTES / 1024 / 1024} MB`);
        return { data: data.toString("base64") };
      })
      .on("files.write", async (params: { key: string; path: string; data: string }) => {
        if (!isSafeRelativePath(params.path)) throw new Error("path must stay inside the workspace");
        const file = await resolveInside(await this.workspace(params.key), params.path);
        await mkdir(dirname(file), { recursive: true });
        const temp = join(dirname(file), `.kervan-upload-${randomUUID()}`);
        const data = Buffer.from(params.data, "base64");
        try {
          await writeFile(temp, data, { mode: 0o640 });
          await rename(temp, file);
        } catch (error) {
          await rm(temp, { force: true });
          throw error;
        }
        return { size: data.length };
      });
  }
}

const unique = (urls: string[]) => [...new Set(urls.map((url) => url.trim()).filter((url) => /^wss?:\/\//.test(url)))];
