import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { AgentRegistry } from "./agents.ts";
import { log } from "./log.ts";
import { KervanError, type ServerMessage, type SessionEvent, type SessionEventBody, type SessionInfo } from "./protocol.ts";
import type { AgentProcess, AgentRunner, PermissionDecision, PermissionRequest } from "./runner.ts";
import type { EventStore } from "./store.ts";

const DEFAULT_TITLE = "Yeni oturum";
const TITLE_CHARS = 60;

interface PendingPermission {
  optionIds: string[];
  resolve: (decision: PermissionDecision) => void;
}

interface Session {
  info: SessionInfo;
  events: SessionEvent[];
  cwd: string;
  process?: AgentProcess;
  /** The agent's own id for this conversation; lets us resume it after a restart. */
  agentSessionId?: string;
  /** Unanswered permission requests by requestId. They wait for as long as the user is away. */
  pending: Map<string, PendingPermission>;
}

type Listener = (message: ServerMessage) => void;

/**
 * Owns agent sessions independently of any client connection: a session keeps running
 * when the Mac goes to sleep, and every connected client sees every session's events.
 * Every event and status change is written to the store first, so a server restart
 * keeps the history; the agent itself is resumed the next time the user writes.
 */
export class SessionManager {
  private readonly sessions = new Map<string, Session>();
  private readonly listeners = new Set<Listener>();
  private readonly runner: AgentRunner;
  private readonly agents: AgentRegistry;
  private readonly workspacesDir: string;
  private readonly store: EventStore;
  /** Set by closeAll: agents may still emit a few events while dying, and the store is closing. */
  private shuttingDown = false;

  constructor(runner: AgentRunner, agents: AgentRegistry, workspacesDir: string, store: EventStore) {
    this.runner = runner;
    this.agents = agents;
    this.workspacesDir = workspacesDir;
    this.store = store;
    for (const stored of store.loadSessions()) {
      const session: Session = {
        info: stored.info,
        events: store.loadEvents(stored.info.id),
        cwd: join(workspacesDir, stored.info.id),
        agentSessionId: stored.agentSessionId,
        pending: new Map(),
      };
      this.sessions.set(session.info.id, session);
      this.recover(session);
    }
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
    if (!this.agents.has(agent)) throw new KervanError("unknown_agent", `no agent named '${agent}'`);

    const id = randomUUID();
    const session: Session = {
      info: { id, agent, title: DEFAULT_TITLE, status: "starting", createdAt: new Date().toISOString() },
      events: [],
      cwd: join(this.workspacesDir, id),
      pending: new Map(),
    };
    await mkdir(session.cwd, { recursive: true });
    this.sessions.set(id, session);
    this.save(session);
    log("info", "session starting", { id, agent });

    this.startAgent(session)
      .then(() => {
        if (session.info.status === "starting") this.setStatus(session, "idle");
      })
      .catch(() => {});

    return { ...session.info };
  }

  prompt(sessionId: string, text: string): void {
    const session = this.require(sessionId);
    if (session.info.status === "running" || session.info.status === "waiting") {
      throw new KervanError("session_busy", "the agent is still answering");
    }
    const resumable = !session.process && session.agentSessionId !== undefined;
    if (session.info.status !== "idle" || (!session.process && !resumable)) {
      throw new KervanError("session_unavailable", `session is ${session.info.status}`);
    }

    if (session.info.title === DEFAULT_TITLE) {
      const line = text.trim().split("\n")[0].replace(/[*_`#>~]/g, "").trim();
      session.info.title = line.length > TITLE_CHARS ? `${line.slice(0, TITLE_CHARS - 1)}…` : line;
    }
    this.record(session, { kind: "user_message", text });
    this.setStatus(session, "running");

    (async () => {
      if (!session.process) {
        await this.startAgent(session, true);
        this.record(session, { kind: "notice", text: "Ajan yeniden başlatıldı; konuşma kaldığı yerden devam ediyor." });
      }
      const stopReason = await session.process!.prompt(text);
      this.record(session, { kind: "turn_end", stopReason });
    })()
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

  /** Shutdown: stop the agents but leave the stored status alone, so the next start recovers. */
  closeAll(): void {
    this.shuttingDown = true;
    for (const session of this.sessions.values()) {
      session.info.status = "closed";
      for (const pending of session.pending.values()) pending.resolve(null);
      session.pending.clear();
      session.process?.close();
    }
  }

  /** Starts (or resumes) the session's agent. On failure the session ends up in `error`. */
  private async startAgent(session: Session, resume = false): Promise<void> {
    try {
      const process = await this.runner.start({
        command: this.agents.get(session.info.agent)!,
        cwd: session.cwd,
        onEvent: (event) => this.record(session, event),
        onPermission: (request) => this.askPermission(session, request),
        ...(resume ? { resumeSessionId: session.agentSessionId } : {}),
      });
      session.process = process;
      session.agentSessionId = process.sessionId;
      this.save(session);
      process.exited.then(() => this.onExit(session, process));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log("error", "agent failed to start", { id: session.info.id, resume, error: message });
      this.record(session, { kind: "error", message: `Ajan başlatılamadı: ${message}` });
      this.setStatus(session, "error", message);
      throw error;
    }
  }

  /**
   * Brings a session loaded from disk to a consistent state: the agent process died with the
   * old server, so close what it left open and make the session resumable if possible.
   */
  private recover(session: Session): void {
    const { status } = session.info;
    if (status === "error" || status === "closed") return;

    const resolved = new Set(session.events.flatMap((e) => (e.kind === "permission_resolved" ? [e.requestId] : [])));
    for (const event of session.events) {
      if (event.kind === "permission_request" && !resolved.has(event.requestId)) {
        this.record(session, { kind: "permission_resolved", requestId: event.requestId, outcome: "cancelled" });
      }
    }
    if (status === "running" || status === "waiting") {
      this.record(session, { kind: "turn_end", stopReason: "interrupted" });
    }

    if (session.agentSessionId) {
      if (status !== "idle") this.setStatus(session, "idle");
    } else {
      this.setStatus(session, "error", "agent session id unknown; cannot resume");
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
    if (this.shuttingDown) return; // recover() on the next start closes whatever was cut off
    const event = { ...body, seq: session.events.length + 1, at: new Date().toISOString() } as SessionEvent;
    this.store.appendEvent(session.info.id, event);
    session.events.push(event);
    this.broadcast({ type: "session.event", sessionId: session.info.id, event });
  }

  private setStatus(session: Session, status: SessionInfo["status"], error?: string): void {
    if (this.shuttingDown) return;
    session.info.status = status;
    if (error) session.info.error = error;
    else delete session.info.error;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  private save(session: Session): void {
    this.store.saveSession({ info: session.info, agentSessionId: session.agentSessionId });
  }

  private onExit(session: Session, process: AgentProcess): void {
    if (session.info.status === "closed" || session.process !== process) return;
    session.process = undefined;
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
