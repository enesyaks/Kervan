import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync, type StatementSync } from "node:sqlite";
import type { SessionEvent, SessionInfo } from "./protocol.ts";

export interface StoredSession {
  info: SessionInfo;
  /** The agent's own session id, used to resume the conversation after a restart. */
  agentSessionId?: string;
}

/** Durable log of sessions and their events. Every event is written before it is broadcast. */
export class EventStore {
  private readonly db: DatabaseSync;
  private readonly upsertSession: StatementSync;
  private readonly insertEvent: StatementSync;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS sessions (
        id               TEXT PRIMARY KEY,
        agent            TEXT NOT NULL,
        title            TEXT NOT NULL,
        status           TEXT NOT NULL,
        created_at       TEXT NOT NULL,
        error            TEXT,
        agent_session_id TEXT
      );
      CREATE TABLE IF NOT EXISTS events (
        session_id TEXT    NOT NULL REFERENCES sessions(id),
        seq        INTEGER NOT NULL,
        at         TEXT    NOT NULL,
        body       TEXT    NOT NULL,
        PRIMARY KEY (session_id, seq)
      );
    `);
    this.upsertSession = this.db.prepare(`
      INSERT INTO sessions (id, agent, title, status, created_at, error, agent_session_id)
      VALUES (:id, :agent, :title, :status, :createdAt, :error, :agentSessionId)
      ON CONFLICT (id) DO UPDATE SET
        title = excluded.title,
        status = excluded.status,
        error = excluded.error,
        agent_session_id = COALESCE(excluded.agent_session_id, sessions.agent_session_id)
    `);
    this.insertEvent = this.db.prepare("INSERT INTO events (session_id, seq, at, body) VALUES (?, ?, ?, ?)");
  }

  saveSession({ info, agentSessionId }: StoredSession): void {
    this.upsertSession.run({
      id: info.id,
      agent: info.agent,
      title: info.title,
      status: info.status,
      createdAt: info.createdAt,
      error: info.error ?? null,
      agentSessionId: agentSessionId ?? null,
    });
  }

  appendEvent(sessionId: string, event: SessionEvent): void {
    const { seq, at, ...body } = event;
    this.insertEvent.run(sessionId, seq, at, JSON.stringify(body));
  }

  loadSessions(): StoredSession[] {
    const rows = this.db.prepare("SELECT * FROM sessions ORDER BY created_at").all() as Record<string, string | null>[];
    return rows.map((row) => ({
      info: {
        id: row.id!,
        agent: row.agent!,
        title: row.title!,
        status: row.status as SessionInfo["status"],
        createdAt: row.created_at!,
        ...(row.error ? { error: row.error } : {}),
      },
      ...(row.agent_session_id ? { agentSessionId: row.agent_session_id } : {}),
    }));
  }

  loadEvents(sessionId: string): SessionEvent[] {
    const rows = this.db
      .prepare("SELECT seq, at, body FROM events WHERE session_id = ? ORDER BY seq")
      .all(sessionId) as { seq: number; at: string; body: string }[];
    return rows.map((row) => ({ ...JSON.parse(row.body), seq: row.seq, at: row.at }));
  }

  close(): void {
    this.db.close();
  }
}
