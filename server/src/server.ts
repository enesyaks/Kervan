import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { log } from "./log.ts";
import type { SessionManager } from "./sessions.ts";
import { VERSION } from "./version.ts";
import { attachWebSocket } from "./ws.ts";

export { VERSION };

export interface ServerOptions {
  token: string;
  sessions: SessionManager;
  startedAt?: number;
  heartbeatMs?: number;
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

export function createKervanServer({ token, sessions, startedAt = Date.now(), heartbeatMs }: ServerOptions): Server {
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://localhost");

    if (req.method === "GET" && url.pathname === "/health") {
      sendJson(res, 200, {
        status: "ok",
        version: VERSION,
        uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
      });
      return;
    }

    log("debug", "not found", { method: req.method, path: url.pathname });
    sendJson(res, 404, { error: "not_found" });
  });

  attachWebSocket(server, token, sessions, heartbeatMs);
  return server;
}
