// Wire types for protocol v1. Spec: protocol/v1.md. Keep in sync with mac/Sources/KervanKit/Protocol.swift.

export const PROTOCOL_VERSION = 1;

export interface PeerInfo {
  name: string;
  version: string;
}

export type ClientMessage =
  | { type: "hello"; protocol: number; client: PeerInfo }
  | { type: "ping"; id: string };

export type ErrorCode = "bad_message" | "unknown_type" | "hello_required" | "unsupported_protocol";

export type ServerMessage =
  | { type: "welcome"; protocol: number; server: PeerInfo }
  | { type: "pong"; id: string }
  | { type: "error"; code: ErrorCode; message: string; id?: string };

export type ParseResult = { ok: true; message: ClientMessage } | { ok: false; code: ErrorCode; message: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPeerInfo(value: unknown): value is PeerInfo {
  return isRecord(value) && typeof value.name === "string" && typeof value.version === "string";
}

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

  switch (data.type) {
    case "hello":
      if (typeof data.protocol !== "number" || !isPeerInfo(data.client)) {
        return { ok: false, code: "bad_message", message: "hello needs 'protocol' and 'client: {name, version}'" };
      }
      return { ok: true, message: { type: "hello", protocol: data.protocol, client: data.client } };
    case "ping":
      if (typeof data.id !== "string") {
        return { ok: false, code: "bad_message", message: "ping needs a string 'id'" };
      }
      return { ok: true, message: { type: "ping", id: data.id } };
    default:
      return { ok: false, code: "unknown_type", message: `unknown message type '${data.type}'` };
  }
}
