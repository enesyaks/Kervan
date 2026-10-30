import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { promisify } from "node:util";
import { KervanError, type ProjectInfo } from "./protocol.ts";

const run = promisify(execFile);
const MAX_INSTRUCTIONS = 20_000;
/** git clone of a large repository can take a while; past this it is given up. */
const CLONE_TIMEOUT_MS = 10 * 60_000;

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/** A folder name from a project name: lowercase ASCII, digits and dashes. */
export function slug(name: string): string {
  const text = name
    .toLocaleLowerCase("tr")
    .replace(/ı/g, "i")
    .normalize("NFD")
    .replace(/\p{M}+/gu, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return text || "proje";
}

/** Only URLs git fetches over the network; no local paths or ext:: helpers. */
const isRemoteUrl = (url: string) => /^(https:\/\/|ssh:\/\/|git@[\w.-]+:)[^\s]+$/.test(url);

/**
 * Projects: a folder on the server (an existing one, a new empty one, or a clone of a repository)
 * with instructions every agent in it gets first. Sessions in a project share its folder.
 */
export class ProjectRegistry {
  private readonly file: string;
  /** New and cloned projects go here. */
  private readonly root: string;
  private projects: Map<string, ProjectInfo>;

  constructor(file: string, root: string) {
    this.file = file;
    this.root = root;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as ProjectInfo[]) : [];
    this.projects = new Map(stored.map((p) => [p.id, p]));
  }

  get(id: string): ProjectInfo | undefined {
    return this.projects.get(id);
  }

  list(): ProjectInfo[] {
    return [...this.projects.values()].sort((a, b) => a.name.localeCompare(b.name, "tr"));
  }

  /**
   * `{id?, name, instructions?}` plus, for a new project, one of `path` (an existing folder on the server)
   * or `gitUrl` (cloned into Kervan's projects folder); with neither, an empty folder is made.
   * An existing project can change only its name and instructions.
   */
  async save(input: Record<string, unknown>): Promise<ProjectInfo> {
    const { id, name, path, gitUrl } = input;
    const instructions = input.instructions ?? "";
    if (typeof name !== "string" || name.trim() === "" || name.length > 80) bad("project needs a name of at most 80 characters");
    if (typeof instructions !== "string" || instructions.length > MAX_INSTRUCTIONS) {
      bad(`instructions must be text of at most ${MAX_INSTRUCTIONS} characters`);
    }
    if (id !== undefined) {
      const existing = typeof id === "string" ? this.projects.get(id) : undefined;
      if (!existing) return bad(`no project '${String(id)}'`);
      const updated = { ...existing, name: (name as string).trim(), instructions: (instructions as string).trim() };
      this.projects.set(updated.id, updated);
      this.persist();
      return updated;
    }

    let folder: string;
    if (typeof path === "string" && path !== "") {
      if (!isAbsolute(path)) bad("path must be an absolute path on the server");
      folder = resolve(path);
      if (!existsSync(folder) || !statSync(folder).isDirectory()) bad(`no folder at ${folder} on the server`);
    } else {
      folder = this.freeFolder(slug(name as string));
      await mkdir(this.root, { recursive: true });
      if (typeof gitUrl === "string" && gitUrl !== "") {
        if (!isRemoteUrl(gitUrl)) bad("gitUrl must be an https://, ssh:// or git@ address");
        try {
          await run("git", ["clone", "--quiet", "--", gitUrl, folder], {
            timeout: CLONE_TIMEOUT_MS,
            env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
          });
        } catch (error) {
          const detail = error instanceof Error && "stderr" in error ? String((error as { stderr: unknown }).stderr).trim() : String(error);
          bad(`couldn't clone ${gitUrl}: ${detail.split("\n").at(-1) || "git failed"}`);
        }
      } else {
        await mkdir(folder, { recursive: true });
      }
    }
    if ([...this.projects.values()].some((p) => p.path === folder)) bad(`a project already uses ${folder}`);

    const project: ProjectInfo = {
      id: randomUUID(),
      name: (name as string).trim(),
      path: folder,
      instructions: (instructions as string).trim(),
      createdAt: new Date().toISOString(),
    };
    this.projects.set(project.id, project);
    this.persist();
    return project;
  }

  /** Forgets the project; its folder and the sessions in it stay. */
  remove(id: string): void {
    if (!this.projects.delete(id)) bad(`no project '${id}'`);
    this.persist();
  }

  private freeFolder(base: string): string {
    for (let n = 1; ; n++) {
      const candidate = join(this.root, n === 1 ? base : `${base}-${n}`);
      if (!existsSync(candidate)) return candidate;
    }
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.list(), null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}
