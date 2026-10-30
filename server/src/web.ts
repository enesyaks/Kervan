import { readFile } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";

/** The web client's files, by the path they are served at. Nothing outside this list is ever read. */
const FILES: Record<string, { file: string; type: string }> = {
  "/": { file: "index.html", type: "text/html; charset=utf-8" },
  "/app.js": { file: "app.js", type: "text/javascript; charset=utf-8" },
  "/style.css": { file: "style.css", type: "text/css; charset=utf-8" },
  "/icon.svg": { file: "icon.svg", type: "image/svg+xml" },
  "/manifest.webmanifest": { file: "manifest.webmanifest", type: "application/manifest+json" },
};

const ROOT = new URL("../web/", import.meta.url);

// The page holds no secrets; the key is typed into it and checked when it opens the WebSocket.
const HEADERS = {
  "content-security-policy":
    "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "cache-control": "no-cache",
};

/** Serves the web client for GET requests to its paths; false when the request is for something else. */
export async function handleWeb(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<boolean> {
  const entry = FILES[pathname];
  if (!entry || (req.method !== "GET" && req.method !== "HEAD")) return false;
  const body = await readFile(new URL(entry.file, ROOT)).catch(() => undefined);
  if (!body) return false;
  res.writeHead(200, { ...HEADERS, "content-type": entry.type, "content-length": body.length });
  res.end(req.method === "HEAD" ? undefined : body);
  return true;
}
