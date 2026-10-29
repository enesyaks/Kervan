import { randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";

const ROUTE = /^\/v1\/sessions\/([^/]+)\/files(?:\/(.+))?$/;
const SKIP_DIRS = new Set([".git", "node_modules"]);
const MAX_ENTRIES = 5000;
const TEMP_PREFIX = ".kervan-upload-";

export interface FileEntry {
  path: string;
  type: "file" | "dir";
  size: number;
  modifiedAt: string;
}

class TooLargeError extends Error {}

/** A workspace-relative path the client may use: no absolute paths, no `..`, no NUL. */
export function isSafeRelativePath(path: string): boolean {
  if (path === "" || path.includes("\0") || isAbsolute(path) || path.startsWith("\\")) return false;
  return !path.split(/[\\/]/).some((part) => part === "..");
}

const isInside = (root: string, path: string) => path === root || path.startsWith(root + sep);

/** Maps a client path into the workspace, refusing anything that would end up outside it. */
export async function resolveInside(root: string, relPath: string): Promise<string> {
  if (!isSafeRelativePath(relPath)) throw new KervanError("bad_message", "path must stay inside the workspace");
  const target = resolve(root, relPath);
  if (!isInside(root, target)) throw new KervanError("bad_message", "path must stay inside the workspace");

  // A symlink inside the workspace could still point out of it: check the deepest part that exists.
  const realRoot = await realpath(root);
  for (let probe = target; ; probe = dirname(probe)) {
    try {
      if (!isInside(realRoot, await realpath(probe))) {
        throw new KervanError("bad_message", "path must stay inside the workspace");
      }
      return target;
    } catch (error) {
      if (error instanceof KervanError || (error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      if (probe === root) return target;
    }
  }
}

export async function listTree(root: string): Promise<{ entries: FileEntry[]; truncated: boolean }> {
  const entries: FileEntry[] = [];
  const queue = [root];
  while (queue.length > 0) {
    const dir = queue.shift()!;
    for (const dirent of await readdir(dir, { withFileTypes: true })) {
      if (dirent.name.startsWith(TEMP_PREFIX) || (dirent.isDirectory() && SKIP_DIRS.has(dirent.name))) continue;
      if (!dirent.isDirectory() && !dirent.isFile()) continue; // symlinks and specials are not followed
      if (entries.length >= MAX_ENTRIES) return { entries, truncated: true };
      const full = join(dir, dirent.name);
      const info = await stat(full);
      entries.push({
        path: relative(root, full).split(sep).join("/"),
        type: dirent.isDirectory() ? "dir" : "file",
        size: dirent.isDirectory() ? 0 : info.size,
        modifiedAt: info.mtime.toISOString(),
      });
      if (dirent.isDirectory()) queue.push(full);
    }
  }
  entries.sort((a, b) => a.path.localeCompare(b.path));
  return { entries, truncated: false };
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(payload) });
  res.end(payload);
}

async function upload(req: IncomingMessage, target: string, maxBytes: number): Promise<number> {
  await mkdir(dirname(target), { recursive: true });
  const temp = join(dirname(target), `${TEMP_PREFIX}${randomUUID()}`);
  let received = 0;
  const limit = new Transform({
    transform(chunk: Buffer, _encoding, done) {
      received += chunk.length;
      done(received > maxBytes ? new TooLargeError() : null, chunk);
    },
  });
  try {
    await pipeline(req, limit, createWriteStream(temp, { mode: 0o640 }));
    await rename(temp, target); // readers never see a half-written file
    return received;
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

/**
 * Serves /v1/sessions/:id/files[/<path>]: GET without a path lists the workspace, GET with one
 * downloads, PUT uploads. The caller has already checked the token. Returns false for other URLs.
 */
export async function handleFiles(
  req: IncomingMessage,
  res: ServerResponse,
  sessions: SessionManager,
  maxUploadBytes: number,
): Promise<boolean> {
  const match = ROUTE.exec(new URL(req.url ?? "/", "http://localhost").pathname);
  if (!match) return false;

  try {
    const root = sessions.workspace(decodeURIComponent(match[1]));
    const relPath = match[2] ? decodeURIComponent(match[2]) : "";

    if (req.method === "GET" && relPath === "") {
      sendJson(res, 200, await listTree(root));
    } else if (req.method === "GET") {
      const target = await resolveInside(root, relPath);
      const info = await stat(target);
      if (!info.isFile()) throw new KervanError("bad_message", "not a file");
      res.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-length": info.size,
        "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(relPath.split("/").at(-1)!)}`,
      });
      await pipeline(createReadStream(target), res);
    } else if (req.method === "PUT" && relPath !== "") {
      const target = await resolveInside(root, relPath);
      const size = await upload(req, target, maxUploadBytes);
      log("info", "file uploaded", { path: relPath, size });
      sendJson(res, 201, { path: relPath, size });
    } else {
      sendJson(res, 405, { error: "method_not_allowed" });
    }
  } catch (error) {
    if (res.headersSent) {
      res.destroy();
    } else if (error instanceof TooLargeError) {
      sendJson(res, 413, { error: "too_large", maxBytes: maxUploadBytes });
      req.resume();
    } else if (error instanceof KervanError) {
      sendJson(res, error.code === "unknown_session" ? 404 : 400, { error: error.code, message: error.message });
    } else if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      sendJson(res, 404, { error: "not_found" });
    } else {
      log("error", "file request failed", { url: req.url, error: String(error) });
      sendJson(res, 500, { error: "internal" });
    }
  }
  return true;
}
