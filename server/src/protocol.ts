// Wire types for protocol v1. Spec: protocol/v1.md. Keep in sync with mac/Sources/KervanKit/Protocol.swift.

export const PROTOCOL_VERSION = 1;

const MAX_PROMPT_CHARS = 100_000;
const MAX_ATTACHMENTS = 20;

export interface PeerInfo {
  name: string;
  version: string;
}

/** `waiting`: the agent is blocked on a permission request the user hasn't answered yet. */
export type SessionStatus = "starting" | "idle" | "running" | "waiting" | "error" | "closed";

export interface PermissionChoice {
  optionId: string;
  name: string;
  /** ACP option kind: allow_once | allow_always | reject_once | reject_always */
  kind: string;
}

export interface SessionInfo {
  id: string;
  agent: string;
  title: string;
  status: SessionStatus;
  createdAt: string;
  archived: boolean;
  /** Skills and MCP servers chosen when the session was created. */
  skills: string[];
  mcpServers: string[];
  error?: string;
}

export type { AgentSummary } from "./catalog.ts";
import type { AgentSummary } from "./catalog.ts";

export interface McpServerSummary {
  name: string;
  transport: "stdio" | "http";
  command?: string;
  args?: string[];
  url?: string;
  /** Names only; values never leave the server. */
  envKeys: string[];
  headerKeys: string[];
}

export interface SearchHit {
  sessionId: string;
  seq: number;
  role: "user" | "agent";
  /** Matched terms are wrapped in \u0001 … \u0002. */
  snippet: string;
}

// Agent-neutral events. Runners translate their agent's own updates (ACP, PTY…) into these.
export type SessionEventBody =
  | { kind: "user_message"; text: string; attachments?: string[] }
  | { kind: "agent_message_chunk"; text: string }
  | { kind: "agent_thought_chunk"; text: string }
  | { kind: "tool_call"; toolCallId: string; title: string; toolKind: string; status: string }
  | { kind: "tool_call_update"; toolCallId: string; title?: string; status?: string }
  | {
      kind: "permission_request";
      requestId: string;
      title: string;
      toolKind: string;
      detail?: string;
      options: PermissionChoice[];
    }
  | { kind: "permission_resolved"; requestId: string; outcome: "selected" | "cancelled"; optionId?: string }
  | { kind: "turn_end"; stopReason: string }
  /** Something Kervan itself did, e.g. recovering the session after a server restart. */
  | { kind: "notice"; text: string }
  | { kind: "error"; message: string };

export type SessionEvent = SessionEventBody & { seq: number; at: string };

export type ClientMessage =
  | { type: "hello"; protocol: number; client: PeerInfo }
  | { type: "ping"; id: string }
  | { type: "session.create"; id: string; agent: string; skills?: string[]; mcpServers?: string[] }
  | { type: "session.list"; id: string }
  | { type: "session.history"; id: string; sessionId: string }
  | { type: "session.prompt"; id: string; sessionId: string; text: string; attachments?: string[] }
  | { type: "session.cancel"; id: string; sessionId: string }
  | { type: "session.permission"; id: string; sessionId: string; requestId: string; optionId: string }
  | { type: "session.rename"; id: string; sessionId: string; title: string }
  | { type: "session.archive"; id: string; sessionId: string; archived: boolean }
  | { type: "session.search"; id: string; query: string }
  | { type: "mcp.list"; id: string }
  | { type: "mcp.save"; id: string; server: Record<string, unknown> }
  | { type: "mcp.delete"; id: string; name: string }
  | { type: "agent.list"; id: string }
  | { type: "agent.save"; id: string; agent: Record<string, unknown> }
  | { type: "agent.delete"; id: string; agentId: string };

export type ErrorCode =
  | "bad_message"
  | "unknown_type"
  | "hello_required"
  | "unsupported_protocol"
  | "unknown_agent"
  | "unknown_session"
  | "session_busy"
  | "session_unavailable"
  | "unknown_request";

export type ServerMessage =
  | { type: "welcome"; protocol: number; server: PeerInfo; agents: string[]; agentDetails: { id: string; name: string }[] }
  | { type: "pong"; id: string }
  | { type: "ok"; id: string }
  | { type: "error"; code: ErrorCode; message: string; id?: string }
  | { type: "session.created"; id: string; session: SessionInfo }
  | { type: "session.list.result"; id: string; sessions: SessionInfo[] }
  | { type: "session.history.result"; id: string; sessionId: string; events: SessionEvent[] }
  | { type: "session.updated"; session: SessionInfo }
  | { type: "session.event"; sessionId: string; event: SessionEvent }
  | { type: "session.search.result"; id: string; hits: SearchHit[] }
  | { type: "mcp.list.result"; id: string; servers: McpServerSummary[] }
  | { type: "agent.list.result"; id: string; agents: AgentSummary[]; nodes: string[] }
  /** Broadcast after the agent catalog changes, in the same shape as `welcome`. */
  | { type: "agents.updated"; agents: string[]; agentDetails: { id: string; name: string }[] };

export type ParseResult =
  | { ok: true; message: ClientMessage }
  | { ok: false; code: ErrorCode; message: string; id?: string };

/** Raised by request handlers; ws.ts turns it into an `error` reply carrying the request id. */
export class KervanError extends Error {
  readonly code: ErrorCode;

  constructor(code: ErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPeerInfo(value: unknown): value is PeerInfo {
  return isRecord(value) && typeof value.name === "string" && typeof value.version === "string";
}

// Request types whose fields are all required strings.
const STRING_FIELDS: Record<string, readonly string[]> = {
  ping: ["id"],
  "session.create": ["id", "agent"],
  "session.list": ["id"],
  "session.history": ["id", "sessionId"],
  "session.prompt": ["id", "sessionId", "text"],
  "session.cancel": ["id", "sessionId"],
  "session.permission": ["id", "sessionId", "requestId", "optionId"],
  "session.rename": ["id", "sessionId", "title"],
  "session.archive": ["id", "sessionId"],
  "session.search": ["id", "query"],
  "mcp.list": ["id"],
  "mcp.save": ["id"],
  "mcp.delete": ["id", "name"],
  "agent.list": ["id"],
  "agent.save": ["id"],
  "agent.delete": ["id", "agentId"],
};

const MAX_SELECTED = 32;

export function parseClientMessage(raw: string): ParseResult {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return { ok: false, code: "bad_message", message: "frame is not valid JSON" };
  }
  if (!isRecord(data) || typeof data.type !== "string") {
    return { ok: false, code: "bad_message", message: "expected a JSON object with a string 'type'" };
  }

  const fail = (code: ErrorCode, message: string): ParseResult =>
    typeof data.id === "string" ? { ok: false, code, message, id: data.id } : { ok: false, code, message };

  if (data.type === "hello") {
    if (typeof data.protocol !== "number" || !isPeerInfo(data.client)) {
      return fail("bad_message", "hello needs 'protocol' and 'client: {name, version}'");
    }
    return { ok: true, message: { type: "hello", protocol: data.protocol, client: data.client } };
  }

  const fields = STRING_FIELDS[data.type];
  if (!fields) {
    return fail("unknown_type", `unknown message type '${data.type}'`);
  }
  const message: Record<string, string> = { type: data.type };
  for (const field of fields) {
    const value = data[field];
    if (typeof value !== "string") {
      return fail("bad_message", `${data.type} needs a string '${field}'`);
    }
    message[field] = value;
  }
  if (data.type === "session.prompt" && (message.text.trim() === "" || message.text.length > MAX_PROMPT_CHARS)) {
    return fail("bad_message", `prompt text must be 1–${MAX_PROMPT_CHARS} characters`);
  }
  if (data.type === "session.create") {
    for (const field of ["skills", "mcpServers"] as const) {
      const list = data[field];
      if (list === undefined) continue;
      if (!Array.isArray(list) || list.length > MAX_SELECTED || !list.every((x) => typeof x === "string")) {
        return fail("bad_message", `${field} must be up to ${MAX_SELECTED} names`);
      }
      (message as Record<string, unknown>)[field] = list;
    }
  }
  if (data.type === "agent.save") {
    if (!isRecord(data.agent)) return fail("bad_message", "agent.save needs an 'agent' object");
    (message as Record<string, unknown>).agent = data.agent;
  }
  if (data.type === "mcp.save") {
    if (!isRecord(data.server)) return fail("bad_message", "mcp.save needs a 'server' object");
    (message as Record<string, unknown>).server = data.server;
  }
  if (data.type === "session.archive") {
    if (typeof data.archived !== "boolean") return fail("bad_message", "session.archive needs a boolean 'archived'");
    (message as Record<string, unknown>).archived = data.archived;
  }
  if (data.type === "session.rename" && (message.title.trim() === "" || message.title.length > 120)) {
    return fail("bad_message", "title must be 1–120 characters");
  }
  if (data.type === "session.prompt" && data.attachments !== undefined) {
    const list = data.attachments;
    if (!Array.isArray(list) || list.length > MAX_ATTACHMENTS || !list.every((a) => typeof a === "string")) {
      return fail("bad_message", `attachments must be up to ${MAX_ATTACHMENTS} paths`);
    }
    (message as Record<string, unknown>).attachments = list;
  }
  return { ok: true, message: message as unknown as ClientMessage };
}
