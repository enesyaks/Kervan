import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { log } from "./log.ts";
import type { SessionManager } from "./sessions.ts";
import { VERSION } from "./version.ts";
import { handleFiles } from "./files.ts";
import { handleSkills, type SkillLibrary } from "./skills.ts";
import { attachWebSocket, isAuthorized } from "./ws.ts";
import { handleOnboarding } from "./onboarding.ts";
import { handleWeb } from "./web.ts";
import { AttemptLimiter, type WebAccess } from "./webaccess.ts";

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
  /** The web client and its paired browsers; without it the server has no web client. */
  web?: WebAccess;
}

const MAX_PAIR_BODY = 2048;

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk: Buffer) => {
      body += chunk.toString("utf8");
      if (body.length > MAX_PAIR_BODY) req.destroy(new Error("too large"));
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
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
  web,
}: ServerOptions): Server {
  // One count of failed browser sign-ins, shared by the key check, pairing and the WebSocket.
  const limiter = new AttemptLimiter();
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

    // Lets the web client tell a wrong key from an unreachable server, which a browser WebSocket can't.
    if (req.method === "GET" && url.pathname === "/v1/check") {
      const remote = req.socket.remoteAddress;
      // The app's own key is never limited; a device key is checked only while the address isn't blocked.
      if (isAuthorized(req.headers.authorization, token)) return sendJson(res, 200, { status: "ok" });
      if (limiter.blocked(remote)) return sendJson(res, 429, { error: "too_many_attempts" });
      const bearer = req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7) : "";
      const ok = Boolean(web?.authenticate(bearer));
      if (!ok) limiter.fail(remote);
      sendJson(res, ok ? 200 : 401, ok ? { status: "ok" } : { error: "unauthorized" });
      return;
    }

    // A browser trades the one-time code the app showed for a key of its own.
    if (req.method === "POST" && url.pathname === "/v1/web/pair") {
      const remote = req.socket.remoteAddress;
      if (!web?.enabled) return sendJson(res, 403, { error: "web_access_off" });
      if (limiter.blocked(remote)) return sendJson(res, 429, { error: "too_many_attempts" });
      void readBody(req).then(
        (body) => {
          let input: { code?: unknown; name?: unknown } = {};
          try { input = JSON.parse(body); } catch { /* answered below as a wrong code */ }
          const paired = typeof input.code === "string" ? web.redeem(input.code, typeof input.name === "string" ? input.name : "") : undefined;
          if (!paired) {
            limiter.fail(remote);
            return sendJson(res, 401, { error: "bad_code" });
          }
          log("info", "web device paired", { remote, device: paired.device.name });
          sendJson(res, 200, { token: paired.token, device: paired.device });
        },
        () => sendJson(res, 413, { error: "too_large" }),
      );
      return;
    }

    // The page itself only while web access is on, so a server that doesn't use it shows nothing.
    if (url.pathname === "/" && req.method === "GET" && !web?.enabled) {
      const text = "Kervan's web access is off. Turn it on in the Kervan app: Settings > Web access.\n";
      res.writeHead(403, { "content-type": "text/plain; charset=utf-8", "content-length": Buffer.byteLength(text) });
      res.end(text);
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
      // The app (the server's key) may do anything here and is never limited. A paired browser may only add a
      // file by name, which always lands in the session's uploads/ folder: it attaches files, nothing more.
      if (!isAuthorized(req.headers.authorization, token)) {
        const remote = req.socket.remoteAddress;
        if (limiter.blocked(remote)) {
          sendJson(res, 429, { error: "too_many_attempts" });
          return;
        }
        const bearer = req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7) : "";
        if (!web?.authenticate(bearer)) {
          limiter.fail(remote);
          sendJson(res, 401, { error: "unauthorized" });
          return;
        }
        const addsByName = /^\/v1\/sessions\/[^/]+\/files\/?$/.test(url.pathname) && !url.searchParams.has("path");
        if ((req.method !== "POST" && req.method !== "PUT") || !addsByName) {
          sendJson(res, 403, { error: "forbidden" });
          return;
        }
      }
      void handleFiles(req, res, sessions, maxUploadBytes).then((handled) => {
        if (!handled) sendJson(res, 404, { error: "not_found" });
      });
      return;
    }

    void (web?.enabled ? handleWeb(req, res, url.pathname) : Promise.resolve(false)).then((served) => {
      if (served) return;
      log("debug", "not found", { method: req.method, path: url.pathname });
      sendJson(res, 404, { error: "not_found" });
    });
  });

  attachWebSocket(server, token, sessions, heartbeatMs, nodeToken, web, limiter);
  return server;
}
