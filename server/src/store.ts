import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync, type StatementSync } from "node:sqlite";
import type { SessionEvent, SessionInfo } from "./protocol.ts";

const SCHEMA_VERSION = 2;

export interface IndexedMessage {
  /** seq of the first event of the message; matches the Mac transcript row id. */
  seq: number;
  role: "user" | "agent";
  text: string;
}

export interface SearchHit extends IndexedMessage {
  sessionId: string;
  /** Text around the match; matched terms are wrapped in \u0001 … \u0002. */
  snippet: string;
}

/** Whole messages from an event log: agent chunks are joined, so a word split across chunks is still found. */
export function foldMessages(events: SessionEvent[]): IndexedMessage[] {
  const messages: IndexedMessage[] = [];
  let agent: IndexedMessage | undefined;
  for (const event of events) {
    if (event.kind === "agent_message_chunk") {
      if (agent) agent.text += event.text;
      else messages.push((agent = { seq: event.seq, role: "agent", text: event.text }));
      continue;
    }
    if (event.kind !== "agent_thought_chunk") agent = undefined;
    if (event.kind === "user_message") messages.push({ seq: event.seq, role: "user", text: event.text });
  }
  return messages;
}

/**
 * Lowercases and strips diacritics one character at a time, so the result has the same length
 * and offsets map back to the original. Turkish ı/İ/I all become i: people search without them.
 */
export function foldText(text: string): string {
  let out = "";
  for (const ch of text) {
    if (ch === "ı" || ch === "İ" || ch === "I") {
      out += "i";
      continue;
    }
    const base = ch.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
    if (base.length === ch.length) out += base;
    else out += ch.toLowerCase().length === ch.length ? ch.toLowerCase() : ch;
  }
  return out;
}

function searchTerms(input: string): string[] {
  return foldText(input)
    .split(/\s+/)
    .map((term) => term.replace(/"/g, ""))
    .filter((term) => term.length > 0);
}

/** User input → FTS5 query: every word must appear, each as a prefix. Quotes keep FTS syntax out. */
export function toMatchQuery(input: string): string | null {
  const terms = searchTerms(input);
  return terms.length > 0 ? terms.map((term) => `"${term}"*`).join(" ") : null;
}

const MARK_START = "\u0001";
const MARK_END = "\u0002";

/** Up to ~120 characters of `original` around the first match, with every match wrapped in markers. */
export function makeSnippet(original: string, terms: string[], radius = 60): string {
  const folded = foldText(original);
  const ranges: [number, number][] = [];
  for (const term of terms) {
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    for (const match of folded.matchAll(new RegExp(`(?<![\\p{L}\\p{N}])${escaped}`, "gu"))) {
      ranges.push([match.index, match.index + term.length]);
    }
  }
  ranges.sort((a, b) => a[0] - b[0]);
  const first = ranges[0]?.[0] ?? 0;
  const start = Math.max(0, first - radius);
  const end = Math.min(original.length, start + radius * 2);

  let out = start > 0 ? "…" : "";
  let cursor = start;
  for (const [from, to] of ranges) {
    if (from < cursor || to > end) continue;
    out += original.slice(cursor, from) + MARK_START + original.slice(from, to) + MARK_END;
    cursor = to;
  }
  return out + original.slice(cursor, end) + (end < original.length ? "…" : "");
}

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
  private readonly insertMessage: StatementSync;
  private readonly deleteMessage: StatementSync;

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
    this.migrate();
    this.upsertSession = this.db.prepare(`
      INSERT INTO sessions (id, agent, title, status, created_at, error, agent_session_id, archived)
      VALUES (:id, :agent, :title, :status, :createdAt, :error, :agentSessionId, :archived)
      ON CONFLICT (id) DO UPDATE SET
        title = excluded.title,
        status = excluded.status,
        error = excluded.error,
        archived = excluded.archived,
        agent_session_id = COALESCE(excluded.agent_session_id, sessions.agent_session_id)
    `);
    this.insertEvent = this.db.prepare("INSERT INTO events (session_id, seq, at, body) VALUES (?, ?, ?, ?)");
    this.insertMessage = this.db.prepare(
      "INSERT INTO message_index (folded, original, session_id, seq, role) VALUES (?, ?, ?, ?, ?)",
    );
    this.deleteMessage = this.db.prepare("DELETE FROM message_index WHERE session_id = ? AND seq = ?");
  }

  /** v2 (M5): archived flag and the full-text index, backfilled from the events already stored. */
  private migrate(): void {
    const { user_version: version } = this.db.prepare("PRAGMA user_version").get() as { user_version: number };
    if (version >= SCHEMA_VERSION) return;
    this.db.exec("BEGIN");
    try {
      this.db.exec(`
        ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
        CREATE VIRTUAL TABLE message_index USING fts5(
          folded, original UNINDEXED, session_id UNINDEXED, seq UNINDEXED, role UNINDEXED,
          tokenize = 'unicode61 remove_diacritics 2'
        );
      `);
      const insert = this.db.prepare(
        "INSERT INTO message_index (folded, original, session_id, seq, role) VALUES (?, ?, ?, ?, ?)",
      );
      const ids = this.db.prepare("SELECT id FROM sessions").all() as { id: string }[];
      for (const { id } of ids) {
        for (const m of foldMessages(this.loadEvents(id))) insert.run(foldText(m.text), m.text, id, m.seq, m.role);
      }
      this.db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
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
      archived: info.archived ? 1 : 0,
    });
  }

  /** Adds or replaces a message in the search index (an agent message grows while it streams). */
  indexMessage(sessionId: string, message: IndexedMessage): void {
    this.deleteMessage.run(sessionId, message.seq);
    this.insertMessage.run(foldText(message.text), message.text, sessionId, message.seq, message.role);
  }

  search(query: string, limit = 50): SearchHit[] {
    const match = toMatchQuery(query);
    if (!match) return [];
    const terms = searchTerms(query);
    const rows = this.db
      .prepare("SELECT session_id, seq, role, original FROM message_index WHERE message_index MATCH ? ORDER BY rank LIMIT ?")
      .all(match, limit) as { session_id: string; seq: number; role: "user" | "agent"; original: string }[];
    return rows.map((row) => ({
      sessionId: row.session_id,
      seq: row.seq,
      role: row.role,
      text: row.original,
      snippet: makeSnippet(row.original, terms),
    }));
  }

  appendEvent(sessionId: string, event: SessionEvent): void {
    const { seq, at, ...body } = event;
    this.insertEvent.run(sessionId, seq, at, JSON.stringify(body));
  }

  loadSessions(): StoredSession[] {
    const rows = this.db.prepare("SELECT * FROM sessions ORDER BY created_at").all() as Record<string, string | number | null>[];
    return rows.map((row) => ({
      info: {
        id: String(row.id),
        agent: String(row.agent),
        title: String(row.title),
        status: row.status as SessionInfo["status"],
        createdAt: String(row.created_at),
        archived: row.archived === 1,
        ...(row.error ? { error: String(row.error) } : {}),
      },
      ...(row.agent_session_id ? { agentSessionId: String(row.agent_session_id) } : {}),
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
