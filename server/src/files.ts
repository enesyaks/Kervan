import { randomUUID } from "node:crypto";
import { constants, type Stats } from "node:fs";
import { lstat, mkdir, open, readdir, readlink, realpath, rename, rm, type FileHandle } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { agentUser } from "./agentuser.ts";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";
import { MAX_NODE_FILE_BYTES } from "./node-agent.ts";

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

export class TooLargeError extends Error {}

/** A workspace-relative path the client may use: no absolute paths, no `..`, no NUL. */
export function isSafeRelativePath(path: string): boolean {
  if (path === "" || path.includes("\0") || isAbsolute(path) || path.startsWith("\\")) return false;
  return !path.split(/[\\/]/).some((part) => part === "..");
}

const isInside = (root: string, path: string) => path === root || path.startsWith(root + sep);
const outside = () => new KervanError("bad_message", "path must stay inside the workspace");

/**
 * The folder `root` really is. An agent user owns the folders above its workspace, so it could swap the workspace for a
 * link to anywhere, and everything would then look "inside". Setup uses no links on these paths, so there any is refused.
 */
export async function realRootOf(root: string, isolated = agentUser() !== undefined): Promise<string> {
  const real = await realpath(root);
  if (isolated && real !== resolve(root)) throw outside();
  return real;
}

/**
 * Where an open file really is, whatever its path has been swapped for since. Linux says so itself; a Mac has no /proc,
 * but no second user there either, so an agent has nothing to gain from a swap and the path is good enough.
 */
async function pathOfOpen(handle: FileHandle, path: string): Promise<string> {
  try {
    return await readlink(`/proc/self/fd/${handle.fd}`);
  } catch {
    return realpath(path);
  }
}

/**
 * Opens a file for reading and only then checks where it turned out to be: an agent can swap a link between any check
 * and any open, but not what's already open. Non-blocking, so a FIFO planted in the folder can't hang a thread.
 */
export async function openInside(realRoot: string, target: string): Promise<{ handle: FileHandle; info: Stats }> {
  const handle = await open(target, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    if (!isInside(realRoot, await pathOfOpen(handle, target))) throw outside();
    const info = await handle.stat();
    if (!info.isFile()) throw new KervanError("bad_message", "not a file");
    return { handle, info };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

/** `mkdir -p` that checks each folder as it goes, so a link on the way can't make it build outside `realRoot`. */
export async function makeDirsInside(realRoot: string, dir: string): Promise<void> {
  const parts = relative(realRoot, dir).split(sep).filter(Boolean);
  let current = realRoot;
  for (const part of parts) {
    current = join(current, part);
    await mkdir(current).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
    });
    if (!isInside(realRoot, await realpath(current))) throw outside();
  }
}

/** Maps a client path into the workspace, refusing anything that would end up outside it. */
export async function resolveInside(root: string, relPath: string): Promise<string> {
  if (!isSafeRelativePath(relPath)) throw outside();
  const target = resolve(root, relPath);
  if (!isInside(root, target)) throw outside();

  // A symlink inside the workspace could still point out of it: check the deepest part that exists.
  const realRoot = await realRootOf(root);
  for (let probe = target; ; probe = dirname(probe)) {
    try {
      if (!isInside(realRoot, await realpath(probe))) throw outside();
      return target;
    } catch (error) {
      if (error instanceof KervanError || (error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      if (probe === root) return target;
    }
  }
}

export async function listTree(root: string): Promise<{ entries: FileEntry[]; truncated: boolean }> {
  const entries: FileEntry[] = [];
  const realRoot = await realRootOf(root);
  const queue = [realRoot];
  while (queue.length > 0) {
    const dir = queue.shift()!;
    for (const dirent of await readdir(dir, { withFileTypes: true })) {
      if (dirent.name.startsWith(TEMP_PREFIX) || (dirent.isDirectory() && SKIP_DIRS.has(dirent.name))) continue;
      if (!dirent.isDirectory() && !dirent.isFile()) continue; // symlinks and specials are not followed
      if (entries.length >= MAX_ENTRIES) return { entries, truncated: true };
      const full = join(dir, dirent.name);
      const info = await lstat(full);
      if (info.isDirectory() !== dirent.isDirectory() || info.isSymbolicLink()) continue; // swapped since the listing
      entries.push({
        path: relative(realRoot, full).split(sep).join("/"),
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

export function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(payload) });
  res.end(payload);
}

/**
 * Streams a request body to `relPath` under `root` via a temp file, so readers never see half a file. The temp file is
 * checked once open, and `rename` looks it up by name again: moved elsewhere by a swapped link, it isn't there to rename.
 */
export async function upload(req: IncomingMessage, root: string, relPath: string, maxBytes: number): Promise<number> {
  const target = await resolveInside(root, relPath);
  const realRoot = await realRootOf(root);
  await makeDirsInside(realRoot, resolve(realRoot, dirname(relPath)));
  const temp = join(dirname(target), `${TEMP_PREFIX}${randomUUID()}`);
  let received = 0;
  const limit = new Transform({
    transform(chunk: Buffer, _encoding, done) {
      received += chunk.length;
      done(received > maxBytes ? new TooLargeError() : null, chunk);
    },
  });
  try {
    const handle = await open(temp, "wx", 0o640); // never an existing file, and never through a link
    if (!isInside(realRoot, await pathOfOpen(handle, temp))) {
      await handle.close();
      throw outside();
    }
    await pipeline(req, limit, handle.createWriteStream());
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
/** `decodeURIComponent`, with a broken %-sequence answered as a bad request rather than a crash of the request. */
export function decode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    throw new KervanError("bad_message", "badly encoded name or path");
  }
}

export async function handleFiles(
  req: IncomingMessage,
  res: ServerResponse,
  sessions: SessionManager,
  maxUploadBytes: number,
): Promise<boolean> {
  const match = ROUTE.exec(new URL(req.url ?? "/", "http://localhost").pathname);
  if (!match) return false;

  try {
    const sessionId = decode(match[1]);
    let relPath = match[2] ? decode(match[2]) : "";
    const parsedUrl = new URL(req.url ?? "/", "http://localhost");
    if (!relPath) {
      const qPath = parsedUrl.searchParams.get("path");
      const qName = parsedUrl.searchParams.get("name");
      const headerName = (req.headers["x-file-name"] as string | undefined)?.trim();
      let name: string | undefined;
      if (qPath) {
        relPath = qPath;
      } else if (qName) {
        name = qName;
      } else if (headerName) {
        name = headerName;
      } else {
        const disposition = req.headers["content-disposition"];
        if (disposition) {
          const m = /filename\*?=(?:UTF-8'')?["']?([^"';]+)["']?/i.exec(disposition);
          if (m) name = decode(m[1]);
        }
      }
      if (name !== undefined) {
        // A bare file name only: it always lands in uploads/.
        if (name === "" || name === "." || name === ".." || /[\\/\0]/.test(name)) {
          throw new KervanError("bad_message", "file name must not contain a path");
        }
        relPath = `uploads/${name}`;
      }
    }
    const where = sessions.location(sessionId);
    if ("node" in where) {
      await remoteFiles(req, res, sessions, where, relPath, maxUploadBytes);
      return true;
    }
    const root = where.path;

    if (req.method === "GET" && relPath === "") {
      sendJson(res, 200, await listTree(root));
    } else if (req.method === "GET") {
      const target = await resolveInside(root, relPath);
      const { handle, info } = await openInside(await realRootOf(root), target);
      res.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-length": info.size,
        "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(relPath.split("/").at(-1)!)}`,
      });
      await pipeline(handle.createReadStream(), res);
    } else if ((req.method === "PUT" || req.method === "POST") && relPath !== "") {
      const size = await upload(req, root, relPath, maxUploadBytes);
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
      const status = error.code === "unknown_session" ? 404 : error.code === "node_offline" ? 503 : 400;
      sendJson(res, status, { error: error.code, message: error.message });
    } else if (error instanceof Error && /ENOENT/.test(error.message)) {
      sendJson(res, 404, { error: "not_found" });
    } else if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      sendJson(res, 404, { error: "not_found" });
    } else {
      log("error", "file request failed", { url: req.url, error: String(error) });
      sendJson(res, 500, { error: "internal" });
    }
  }
  return true;
}

/**
 * The same routes for a session whose workspace is on a node: the node lists, reads and writes inside
 * its own folder, and whole files travel over the hub's connection to it (so they are capped).
 */
async function remoteFiles(
  req: IncomingMessage,
  res: ServerResponse,
  sessions: SessionManager,
  where: { node: string; key: string },
  relPath: string,
  maxUploadBytes: number,
): Promise<void> {
  const nodes = sessions.nodes;
  if (!nodes) throw new KervanError("node_offline", "this server doesn't accept nodes");
  if (relPath !== "" && !isSafeRelativePath(relPath)) throw new KervanError("bad_message", "path must stay inside the workspace");

  if (req.method === "GET" && relPath === "") {
    sendJson(res, 200, await nodes.listFiles(where.node, where.key));
  } else if (req.method === "GET") {
    const data = await nodes.readFile(where.node, where.key, relPath);
    res.writeHead(200, {
      "content-type": "application/octet-stream",
      "content-length": data.length,
      "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(relPath.split("/").at(-1)!)}`,
    });
    res.end(data);
  } else if ((req.method === "PUT" || req.method === "POST") && relPath !== "") {
    const limit = Math.min(maxUploadBytes, MAX_NODE_FILE_BYTES);
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req as AsyncIterable<Buffer>) {
      size += chunk.length;
      if (size > limit) throw new TooLargeError();
      chunks.push(chunk);
    }
    await nodes.writeFile(where.node, where.key, relPath, Buffer.concat(chunks));
    log("info", "file uploaded to node", { node: where.node, path: relPath, size });
    sendJson(res, 201, { path: relPath, size });
  } else {
    sendJson(res, 405, { error: "method_not_allowed" });
  }
}
