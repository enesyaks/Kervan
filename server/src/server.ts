import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { log } from "./log.ts";
import type { SessionManager } from "./sessions.ts";
import { VERSION } from "./version.ts";
import { handleFiles } from "./files.ts";
import { handleSkills, type SkillLibrary } from "./skills.ts";
import { attachWebSocket, isAuthorized } from "./ws.ts";
import { handleOnboarding } from "./onboarding.ts";

export { VERSION };

export interface ServerOptions {
  token: string;
  sessions: SessionManager;
  startedAt?: number;
  heartbeatMs?: number;
  maxUploadBytes?: number;
  skills?: SkillLibrary;
  /** Lets `kervan-node` processes connect on /v1/node; without it nodes are refused. */
  nodeToken?: string;
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

const DEFAULT_MAX_UPLOAD_BYTES = 512 * 1024 * 1024;

export function createKervanServer({
  token,
  sessions,
  startedAt = Date.now(),
  heartbeatMs,
  maxUploadBytes = DEFAULT_MAX_UPLOAD_BYTES,
  skills,
  nodeToken,
}: ServerOptions): Server {
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

    // Node setup: the invite code in the request is the credential (see onboarding.ts).
    if (url.pathname.startsWith("/v1/node/") && sessions.nodes) {
      void handleOnboarding(req, res, sessions.nodes);
      return;
    }

    if (url.pathname === "/v1/skills" || url.pathname.startsWith("/v1/skills/")) {
      if (!isAuthorized(req.headers.authorization, token)) {
        sendJson(res, 401, { error: "unauthorized" });
        return;
      }
      if (!skills) {
        sendJson(res, 404, { error: "not_found" });
        return;
      }
      void handleSkills(req, res, skills, maxUploadBytes);
      return;
    }

    if (url.pathname.startsWith("/v1/sessions/")) {
      if (!isAuthorized(req.headers.authorization, token)) {
        sendJson(res, 401, { error: "unauthorized" });
        return;
      }
      void handleFiles(req, res, sessions, maxUploadBytes).then((handled) => {
        if (!handled) sendJson(res, 404, { error: "not_found" });
      });
      return;
    }

    log("debug", "not found", { method: req.method, path: url.pathname });
    sendJson(res, 404, { error: "not_found" });
  });

  attachWebSocket(server, token, sessions, heartbeatMs, nodeToken);
  return server;
}
