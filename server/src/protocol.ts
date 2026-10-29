// Wire types for protocol v1. Spec: protocol/v1.md. Keep in sync with mac/Sources/KervanKit/Protocol.swift.

export const PROTOCOL_VERSION = 1;

const MAX_PROMPT_CHARS = 100_000;

export interface PeerInfo {
  name: string;
  version: string;
}

export type SessionStatus = "starting" | "idle" | "running" | "error" | "closed";

export interface SessionInfo {
  id: string;
  agent: string;
  title: string;
  status: SessionStatus;
  createdAt: string;
  error?: string;
}

// Agent-neutral events. Runners translate their agent's own updates (ACP, PTY…) into these.
export type SessionEventBody =
  | { kind: "user_message"; text: string }
  | { kind: "agent_message_chunk"; text: string }
  | { kind: "agent_thought_chunk"; text: string }
  | { kind: "tool_call"; toolCallId: string; title: string; toolKind: string; status: string }
  | { kind: "tool_call_update"; toolCallId: string; title?: string; status?: string }
  | { kind: "permission_auto_rejected"; title: string }
  | { kind: "turn_end"; stopReason: string }
  | { kind: "error"; message: string };

export type SessionEvent = SessionEventBody & { seq: number; at: string };

export type ClientMessage =
  | { type: "hello"; protocol: number; client: PeerInfo }
  | { type: "ping"; id: string }
  | { type: "session.create"; id: string; agent: string }
  | { type: "session.list"; id: string }
  | { type: "session.history"; id: string; sessionId: string }
  | { type: "session.prompt"; id: string; sessionId: string; text: string }
  | { type: "session.cancel"; id: string; sessionId: string };

export type ErrorCode =
  | "bad_message"
  | "unknown_type"
  | "hello_required"
  | "unsupported_protocol"
  | "unknown_agent"
  | "unknown_session"
  | "session_busy"
  | "session_unavailable";

export type ServerMessage =
  | { type: "welcome"; protocol: number; server: PeerInfo; agents: string[] }
  | { type: "pong"; id: string }
  | { type: "ok"; id: string }
  | { type: "error"; code: ErrorCode; message: string; id?: string }
  | { type: "session.created"; id: string; session: SessionInfo }
  | { type: "session.list.result"; id: string; sessions: SessionInfo[] }
  | { type: "session.history.result"; id: string; sessionId: string; events: SessionEvent[] }
  | { type: "session.updated"; session: SessionInfo }
  | { type: "session.event"; sessionId: string; event: SessionEvent };

export type ParseResult = { ok: true; message: ClientMessage } | { ok: false; code: ErrorCode; message: string };

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
};

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

  if (data.type === "hello") {
    if (typeof data.protocol !== "number" || !isPeerInfo(data.client)) {
      return { ok: false, code: "bad_message", message: "hello needs 'protocol' and 'client: {name, version}'" };
    }
    return { ok: true, message: { type: "hello", protocol: data.protocol, client: data.client } };
  }

  const fields = STRING_FIELDS[data.type];
  if (!fields) {
    return { ok: false, code: "unknown_type", message: `unknown message type '${data.type}'` };
  }
  const message: Record<string, string> = { type: data.type };
  for (const field of fields) {
    const value = data[field];
    if (typeof value !== "string") {
      return { ok: false, code: "bad_message", message: `${data.type} needs a string '${field}'` };
    }
    message[field] = value;
  }
  if (data.type === "session.prompt" && (message.text.trim() === "" || message.text.length > MAX_PROMPT_CHARS)) {
    return { ok: false, code: "bad_message", message: `prompt text must be 1–${MAX_PROMPT_CHARS} characters` };
  }
  return { ok: true, message: message as unknown as ClientMessage };
}
