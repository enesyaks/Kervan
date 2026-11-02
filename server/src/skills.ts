import { existsSync, mkdirSync } from "node:fs";
import { cp, lstat, mkdir, readdir, readFile, rm } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join, relative, resolve, sep } from "node:path";
import { parse } from "yaml";
import { decode, isSafeRelativePath, listTree, makeDirsInside, realRootOf, sendJson, TooLargeError, upload } from "./files.ts";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";

const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
const ROUTE = /^\/v1\/skills(?:\/([^/]+)(?:\/(.+))?)?$/;

export interface SkillInfo {
  name: string;
  description: string;
  files: number;
}

/** The `description:` from SKILL.md's YAML front matter, or "" when there is none. */
export function skillDescription(markdown: string): string {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(markdown);
  if (!match) return "";
  try {
    const front = parse(match[1]) as { description?: unknown } | null;
    return typeof front?.description === "string" ? front.description.trim() : "";
  } catch {
    return "";
  }
}

/** Agent Skills on the server: `<root>/<name>/SKILL.md` plus whatever files the skill ships. */
export class SkillLibrary {
  readonly root: string;

  constructor(root: string) {
    this.root = root;
    mkdirSync(root, { recursive: true });
  }

  dir(name: string): string {
    if (!NAME.test(name)) throw new KervanError("bad_message", `skill name '${name}' must be lowercase letters, digits or '-'`);
    return join(this.root, name);
  }

  /** A skill counts once its SKILL.md has arrived; half-uploaded folders are not offered. */
  has(name: string): boolean {
    return NAME.test(name) && existsSync(join(this.root, name, "SKILL.md"));
  }

  async list(): Promise<SkillInfo[]> {
    const skills: SkillInfo[] = [];
    for (const entry of await readdir(this.root, { withFileTypes: true })) {
      if (!entry.isDirectory() || !this.has(entry.name)) continue;
      const dir = join(this.root, entry.name);
      const description = skillDescription(await readFile(join(dir, "SKILL.md"), "utf8"));
      const { entries } = await listTree(dir);
      skills.push({ name: entry.name, description, files: entries.filter((e) => e.type === "file").length });
    }
    return skills.sort((a, b) => a.name.localeCompare(b.name));
  }

  async describe(names: string[]): Promise<{ name: string; description: string }[]> {
    return Promise.all(
      names.map(async (name) => ({ name, description: skillDescription(await readFile(join(this.dir(name), "SKILL.md"), "utf8")) })),
    );
  }

  async remove(name: string): Promise<void> {
    await rm(this.dir(name), { recursive: true, force: true });
  }

  /**
   * Copies the skills into `<workspace>/<folder>/<name>`: a snapshot, so later library edits don't change a running
   * session. The folder can come from a cloned repository, and the server copies with more rights than the agent has, so
   * a link there would write the skill wherever the repository chose: that's refused.
   */
  async copyInto(names: string[], workspace: string, folder: string): Promise<void> {
    if (!isSafeRelativePath(folder)) throw new KervanError("bad_message", "the skills folder must be inside the workspace");
    const realRoot = await realRootOf(workspace);
    const target = resolve(realRoot, folder);
    await refuseLinks(realRoot, target);
    await makeDirsInside(realRoot, target);
    for (const name of names) {
      await refuseLinks(target, join(target, name));
      await refuseLinksBelow(join(target, name));
      await cp(this.dir(name), join(target, name), { recursive: true });
    }
  }
}

const linkRefused = (path: string) =>
  new KervanError("bad_message", `${path} is a symbolic link, so Kervan won't copy skills there. Remove the link and try again.`);

const isLink = (path: string) =>
  lstat(path).then(
    (info) => info.isSymbolicLink(),
    (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return false;
      throw error;
    },
  );

/** Refuses a link on the way from `from` down to `path`. */
async function refuseLinks(from: string, path: string): Promise<void> {
  let current = from;
  for (const part of relative(from, path).split(sep).filter(Boolean)) {
    current = join(current, part);
    if (await isLink(current)) throw linkRefused(relative(from, current));
  }
}

/** Refuses a link anywhere inside a skill's folder from an earlier copy: `cp` would write through it. */
async function refuseLinksBelow(dir: string): Promise<void> {
  const entries = await readdir(dir, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  for (const entry of entries) {
    if (entry.isSymbolicLink()) throw linkRefused(join(dir, entry.name));
    if (entry.isDirectory()) await refuseLinksBelow(join(dir, entry.name));
  }
}

/**
 * GET /v1/skills lists, PUT /v1/skills/<name>/<path> uploads one file, DELETE /v1/skills/<name> removes.
 * The caller has already checked the token. Returns false for other URLs.
 */
export async function handleSkills(
  req: IncomingMessage,
  res: ServerResponse,
  library: SkillLibrary,
  maxUploadBytes: number,
): Promise<boolean> {
  const match = ROUTE.exec(new URL(req.url ?? "/", "http://localhost").pathname);
  if (!match) return false;

  try {
    const name = match[1] ? decode(match[1]) : undefined;
    const relPath = match[2] ? decode(match[2]) : undefined;
    if (req.method === "GET" && !name) {
      sendJson(res, 200, { skills: await library.list() });
    } else if (req.method === "PUT" && name && relPath) {
      const dir = library.dir(name);
      await mkdir(dir, { recursive: true });
      const size = await upload(req, dir, relPath, maxUploadBytes);
      sendJson(res, 201, { name, path: relPath, size });
    } else if (req.method === "DELETE" && name && !relPath) {
      await library.remove(name);
      log("info", "skill removed", { name });
      res.writeHead(204).end();
    } else {
      sendJson(res, 405, { error: "method_not_allowed" });
    }
  } catch (error) {
    if (error instanceof TooLargeError) {
      sendJson(res, 413, { error: "too_large", maxBytes: maxUploadBytes });
      req.resume();
    } else if (error instanceof KervanError) {
      sendJson(res, 400, { error: error.code, message: error.message });
    } else {
      log("error", "skill request failed", { url: req.url, error: String(error) });
      sendJson(res, 500, { error: "internal" });
    }
  }
  return true;
}
