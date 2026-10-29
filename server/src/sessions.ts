import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { AgentRegistry } from "./agents.ts";
import { log } from "./log.ts";
import { KervanError, type ServerMessage, type SessionEvent, type SessionEventBody, type SessionInfo } from "./protocol.ts";
import type { AgentProcess, AgentRunner, PermissionDecision, PermissionRequest } from "./runner.ts";

const DEFAULT_TITLE = "Yeni oturum";
const TITLE_CHARS = 60;

interface PendingPermission {
  optionIds: string[];
  resolve: (decision: PermissionDecision) => void;
}

interface Session {
  info: SessionInfo;
  events: SessionEvent[];
  process?: AgentProcess;
  /** Unanswered permission requests by requestId. They wait for as long as the user is away. */
  pending: Map<string, PendingPermission>;
}

type Listener = (message: ServerMessage) => void;

/**
 * Owns agent sessions independently of any client connection: a session keeps running
 * when the Mac goes to sleep, and every connected client sees every session's events.
 * Events live in memory until M3 adds the SQLite log.
 */
export class SessionManager {
  private readonly sessions = new Map<string, Session>();
  private readonly listeners = new Set<Listener>();
  private readonly runner: AgentRunner;
  private readonly agents: AgentRegistry;
  private readonly workspacesDir: string;

  constructor(runner: AgentRunner, agents: AgentRegistry, workspacesDir: string) {
    this.runner = runner;
    this.agents = agents;
    this.workspacesDir = workspacesDir;
  }

  get agentKinds(): string[] {
    return [...this.agents.keys()];
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  list(): SessionInfo[] {
    return [...this.sessions.values()].map((s) => s.info);
  }

  history(sessionId: string): SessionEvent[] {
    return this.require(sessionId).events;
  }

  async create(agent: string): Promise<SessionInfo> {
    const command = this.agents.get(agent);
    if (!command) throw new KervanError("unknown_agent", `no agent named '${agent}'`);

    const id = randomUUID();
    const cwd = join(this.workspacesDir, id);
    await mkdir(cwd, { recursive: true });

    const session: Session = {
      info: { id, agent, title: DEFAULT_TITLE, status: "starting", createdAt: new Date().toISOString() },
      events: [],
      pending: new Map(),
    };
    this.sessions.set(id, session);
    log("info", "session starting", { id, agent });

    this.runner
      .start({
        command,
        cwd,
        onEvent: (event) => this.record(session, event),
        onPermission: (request) => this.askPermission(session, request),
      })
      .then((process) => {
        session.process = process;
        process.exited.then(() => this.onExit(session));
        if (session.info.status === "starting") this.setStatus(session, "idle");
      })
      .catch((error: unknown) => {
        const message = error instanceof Error ? error.message : String(error);
        log("error", "session failed to start", { id, error: message });
        this.record(session, { kind: "error", message: `Ajan başlatılamadı: ${message}` });
        this.setStatus(session, "error", message);
      });

    return { ...session.info };
  }

  prompt(sessionId: string, text: string): void {
    const session = this.require(sessionId);
    if (session.info.status === "running" || session.info.status === "waiting") {
      throw new KervanError("session_busy", "the agent is still answering");
    }
    if (session.info.status !== "idle" || !session.process) {
      throw new KervanError("session_unavailable", `session is ${session.info.status}`);
    }

    if (session.info.title === DEFAULT_TITLE) {
      const line = text.trim().split("\n")[0].replace(/[*_`#>~]/g, "").trim();
      session.info.title = line.length > TITLE_CHARS ? `${line.slice(0, TITLE_CHARS - 1)}…` : line;
    }
    this.record(session, { kind: "user_message", text });
    this.setStatus(session, "running");

    session.process
      .prompt(text)
      .then((stopReason) => this.record(session, { kind: "turn_end", stopReason }))
      .catch((error: unknown) => {
        this.record(session, { kind: "error", message: error instanceof Error ? error.message : String(error) });
      })
      .finally(() => {
        if (session.info.status === "running" || session.info.status === "waiting") this.setStatus(session, "idle");
      });
  }

  /** Answers a pending permission request with one of the options the agent offered. */
  respond(sessionId: string, requestId: string, optionId: string): void {
    const session = this.require(sessionId);
    const pending = session.pending.get(requestId);
    if (!pending) throw new KervanError("unknown_request", `no pending permission request '${requestId}'`);
    if (!pending.optionIds.includes(optionId)) {
      throw new KervanError("bad_message", `'${optionId}' is not one of the offered options`);
    }
    this.resolvePermission(session, requestId, optionId);
  }

  async cancel(sessionId: string): Promise<void> {
    const session = this.require(sessionId);
    if (session.info.status !== "running" && session.info.status !== "waiting") return;
    // ACP: a cancelling client must answer its open permission requests with "cancelled".
    for (const requestId of [...session.pending.keys()]) this.resolvePermission(session, requestId, null);
    await session.process?.cancel();
  }

  closeAll(): void {
    for (const session of this.sessions.values()) {
      session.info.status = "closed";
      for (const pending of session.pending.values()) pending.resolve(null);
      session.pending.clear();
      session.process?.close();
    }
  }

  private askPermission(session: Session, request: PermissionRequest): Promise<PermissionDecision> {
    const requestId = randomUUID();
    return new Promise((resolve) => {
      session.pending.set(requestId, { optionIds: request.options.map((o) => o.optionId), resolve });
      this.record(session, { kind: "permission_request", requestId, ...request });
      this.setStatus(session, "waiting");
    });
  }

  private resolvePermission(session: Session, requestId: string, optionId: PermissionDecision): void {
    const pending = session.pending.get(requestId);
    if (!pending) return;
    session.pending.delete(requestId);
    this.record(
      session,
      optionId
        ? { kind: "permission_resolved", requestId, outcome: "selected", optionId }
        : { kind: "permission_resolved", requestId, outcome: "cancelled" },
    );
    if (session.pending.size === 0 && session.info.status === "waiting") this.setStatus(session, "running");
    pending.resolve(optionId);
  }

  private require(sessionId: string): Session {
    const session = this.sessions.get(sessionId);
    if (!session) throw new KervanError("unknown_session", `no session '${sessionId}'`);
    return session;
  }

  private record(session: Session, body: SessionEventBody): void {
    const event = { ...body, seq: session.events.length + 1, at: new Date().toISOString() } as SessionEvent;
    session.events.push(event);
    this.broadcast({ type: "session.event", sessionId: session.info.id, event });
  }

  private setStatus(session: Session, status: SessionInfo["status"], error?: string): void {
    session.info.status = status;
    if (error) session.info.error = error;
    else delete session.info.error;
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  private onExit(session: Session): void {
    if (session.info.status === "closed") return;
    for (const pending of session.pending.values()) pending.resolve(null);
    session.pending.clear();
    log("warn", "agent process exited", { id: session.info.id });
    this.record(session, { kind: "error", message: "Ajan süreci beklenmedik şekilde kapandı." });
    this.setStatus(session, "error", "agent process exited");
  }

  private broadcast(message: ServerMessage): void {
    for (const listener of this.listeners) listener(message);
  }
}
