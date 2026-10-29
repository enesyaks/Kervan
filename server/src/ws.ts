import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import { log } from "./log.ts";
import { KervanError, PROTOCOL_VERSION, parseClientMessage, type ClientMessage, type ServerMessage } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";
import { VERSION } from "./version.ts";

export const WS_PATH = "/v1/ws";
const HEARTBEAT_MS = 30_000;
const MAX_FRAME_BYTES = 1024 * 1024;

const sha256 = (value: string) => createHash("sha256").update(value).digest();

// Hashing both sides first gives equal-length buffers, so the compare is constant-time.
export function isAuthorized(header: string | undefined, token: string): boolean {
  if (!header?.startsWith("Bearer ")) return false;
  return timingSafeEqual(sha256(header.slice("Bearer ".length)), sha256(token));
}

function rejectUpgrade(socket: Duplex, status: number, reason: string): void {
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

function send(ws: WebSocket, message: ServerMessage): void {
  ws.send(JSON.stringify(message));
}

async function handleRequest(ws: WebSocket, message: Exclude<ClientMessage, { type: "hello" }>, sessions: SessionManager) {
  switch (message.type) {
    case "ping":
      return send(ws, { type: "pong", id: message.id });
    case "session.create":
      return send(ws, { type: "session.created", id: message.id, session: await sessions.create(message.agent) });
    case "session.list":
      return send(ws, { type: "session.list.result", id: message.id, sessions: sessions.list() });
    case "session.history":
      return send(ws, {
        type: "session.history.result",
        id: message.id,
        sessionId: message.sessionId,
        events: sessions.history(message.sessionId),
      });
    case "session.prompt":
      sessions.prompt(message.sessionId, message.text, message.attachments);
      return send(ws, { type: "ok", id: message.id });
    case "session.cancel":
      await sessions.cancel(message.sessionId);
      return send(ws, { type: "ok", id: message.id });
    case "session.permission":
      sessions.respond(message.sessionId, message.requestId, message.optionId);
      return send(ws, { type: "ok", id: message.id });
    case "session.rename":
      sessions.rename(message.sessionId, message.title);
      return send(ws, { type: "ok", id: message.id });
    case "session.archive":
      sessions.archive(message.sessionId, message.archived);
      return send(ws, { type: "ok", id: message.id });
    case "session.search":
      return send(ws, {
        type: "session.search.result",
        id: message.id,
        hits: sessions.search(message.query).map(({ sessionId, seq, role, snippet }) => ({ sessionId, seq, role, snippet })),
      });
  }
}

function handleConnection(ws: WebSocket, req: IncomingMessage, sessions: SessionManager): void {
  const remote = req.socket.remoteAddress;
  let greeted = false;
  let unsubscribe: (() => void) | undefined;
  log("info", "ws connected", { remote });

  ws.on("message", async (data, isBinary) => {
    if (isBinary) {
      send(ws, { type: "error", code: "bad_message", message: "binary frames are not supported" });
      return;
    }
    const parsed = parseClientMessage(data.toString());
    if (!parsed.ok) {
      send(ws, { type: "error", code: parsed.code, message: parsed.message, ...(parsed.id ? { id: parsed.id } : {}) });
      return;
    }

    const message = parsed.message;
    if (message.type === "hello") {
      if (message.protocol !== PROTOCOL_VERSION) {
        send(ws, {
          type: "error",
          code: "unsupported_protocol",
          message: `server speaks protocol ${PROTOCOL_VERSION}, client sent ${message.protocol}`,
        });
        ws.close(4000, "unsupported protocol");
        return;
      }
      if (!greeted) {
        greeted = true;
        unsubscribe = sessions.subscribe((event) => {
          if (ws.readyState === ws.OPEN) send(ws, event);
        });
      }
      log("info", "ws hello", { remote, client: message.client });
      send(ws, {
        type: "welcome",
        protocol: PROTOCOL_VERSION,
        server: { name: "kervan", version: VERSION },
        agents: sessions.agentKinds,
        agentDetails: sessions.agentDetails,
      });
      return;
    }

    if (!greeted) {
      send(ws, { type: "error", code: "hello_required", message: "send 'hello' first", id: message.id });
      return;
    }

    try {
      await handleRequest(ws, message, sessions);
    } catch (error) {
      if (!(error instanceof KervanError)) {
        log("error", "request failed", { type: message.type, error: String(error) });
        throw error;
      }
      send(ws, { type: "error", code: error.code, message: error.message, id: message.id });
    }
  });

  ws.on("close", (code) => {
    unsubscribe?.();
    log("info", "ws closed", { remote, code });
  });
}

export function attachWebSocket(
  server: Server,
  token: string,
  sessions: SessionManager,
  heartbeatMs = HEARTBEAT_MS,
): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });
  const alive = new WeakSet<WebSocket>();

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
    if (path !== WS_PATH) {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    if (!isAuthorized(req.headers.authorization, token)) {
      log("warn", "ws auth rejected", { remote: req.socket.remoteAddress });
      rejectUpgrade(socket, 401, "Unauthorized");
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
  });

  wss.on("connection", (ws: WebSocket, req: IncomingMessage) => {
    alive.add(ws);
    ws.on("pong", () => alive.add(ws));
    handleConnection(ws, req, sessions);
  });

  // Drop clients that missed a whole heartbeat round (sleeping laptop, dead network).
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!alive.has(ws)) {
        ws.terminate();
        continue;
      }
      alive.delete(ws);
      ws.ping();
    }
  }, heartbeatMs);
  heartbeat.unref();

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const ws of wss.clients) ws.close(1001, "server shutting down");
  });

  return wss;
}
