import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { isSafeRelativePath } from "./files.ts";
import { agentUser, runAsAgent } from "./agentuser.ts";
import { agentGitEnv, gitEnv, workspaceGit } from "./safegit.ts";
import type { ChangeSet, ChangedFile } from "./protocol.ts";

const run = promisify(execFile);
const IDENTITY = ["-c", "user.name=Kervan", "-c", "user.email=kervan@localhost", "-c", "core.quotepath=off"];
/** The Changes panel shows at most this much of the patch; the file list is always whole. */
export const MAX_PATCH_CHARS = 400_000;
/** Kept out of checkpoints: rebuilt by tools, often huge, never what the user wants back. */
export const EXCLUDES = ["node_modules/", ".venv/", "venv/", "__pycache__/", ".kervan-upload-*", ".DS_Store", "dist/", "build/", "target/", ".next/"];

/**
 * Snapshots of a session's folder, one before every message, so changes can be shown and undone.
 * They live in Kervan's own git store per session (outside the folder), so a repository the user
 * works in is never touched: its own .git is ignored and its history stays as it was.
 */
export class Checkpoints {
  private readonly root: string;
  /** One git command at a time per session; git locks its index. */
  private readonly queues = new Map<string, Promise<unknown>>();

  constructor(root: string) {
    this.root = root;
  }

  /** Commits the folder as it is and returns the commit. */
  snapshot(sessionId: string, cwd: string, label: string): Promise<string> {
    return this.serial(sessionId, async () => {
      await this.ensure(sessionId, cwd);
      await this.git(sessionId, cwd, "add", "-A");
      await this.git(sessionId, cwd, "commit", "--allow-empty", "--no-verify", "-q", "-m", label);
      return (await this.git(sessionId, cwd, "rev-parse", "HEAD")).trim();
    });
  }

  /** What changed since `commit`, files the agent created included. */
  changes(sessionId: string, cwd: string, commit: string): Promise<Pick<ChangeSet, "files" | "patch" | "truncated">> {
    return this.serial(sessionId, async () => {
      await this.ensure(sessionId, cwd);
      await this.git(sessionId, cwd, "add", "-A");
      const numstat = await this.git(sessionId, cwd, "diff", "--cached", "--numstat", "--no-renames", commit);
      const kinds = new Map(
        (await this.git(sessionId, cwd, "diff", "--cached", "--name-status", "--no-renames", commit))
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            const [code, ...path] = line.split("\t");
            return [path.join("\t"), code] as const;
          }),
      );
      const files: ChangedFile[] = numstat
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [added, deleted, ...path] = line.split("\t");
          const name = path.join("\t");
          const code = kinds.get(name);
          return {
            path: name,
            status: code === "A" ? "added" : code === "D" ? "deleted" : "modified",
            // Binary files show "-" in numstat.
            additions: Number(added) || 0,
            deletions: Number(deleted) || 0,
          };
        });
      const patch = files.length > 0 ? await this.git(sessionId, cwd, "diff", "--cached", "--no-renames", commit) : "";
      return {
        files,
        patch: patch.length > MAX_PATCH_CHARS ? patch.slice(0, MAX_PATCH_CHARS) : patch,
        truncated: patch.length > MAX_PATCH_CHARS,
      };
    });
  }

  /**
   * Puts the folder (or just `paths`) back as it was at `commit`: changed and deleted files come back,
   * files created since are removed. Returns the paths it touched.
   */
  restore(sessionId: string, cwd: string, commit: string, paths?: string[]): Promise<string[]> {
    if (paths && !paths.every(isSafeRelativePath)) return Promise.reject(new Error("paths must stay inside the workspace"));
    return this.serial(sessionId, async () => {
      await this.ensure(sessionId, cwd);
      await this.git(sessionId, cwd, "add", "-A");
      const changed = (await this.git(sessionId, cwd, "diff", "--cached", "--name-status", "--no-renames", commit, "--", ...(paths ?? [])))
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [code, ...path] = line.split("\t");
          return { code, path: path.join("\t") };
        });
      for (const { path } of changed.filter((c) => c.code === "A")) await rm(join(cwd, path), { force: true });
      const back = changed.filter((c) => c.code !== "A").map((c) => c.path);
      if (back.length > 0) await this.git(sessionId, cwd, "checkout", commit, "--", ...back);
      return changed.map((c) => c.path);
    });
  }

  private gitDir(sessionId: string): string {
    return join(this.root, sessionId);
  }

  private async ensure(sessionId: string, cwd: string): Promise<void> {
    const dir = this.gitDir(sessionId);
    if (existsSync(join(dir, "HEAD"))) return;
    await mkdir(dir, { recursive: true, mode: agentUser() ? 0o770 : 0o700 });
    if (agentUser()) await runAsAgent("git", ["--git-dir", dir, "init", "-q"], { env: agentGitEnv() });
    else await run("git", ["--git-dir", dir, "init", "-q"], { env: gitEnv() });
    await mkdir(join(dir, "info"), { recursive: true });
    await writeFile(join(dir, "info", "exclude"), `${EXCLUDES.join("\n")}\n`);
  }

  private async git(sessionId: string, cwd: string, ...args: string[]): Promise<string> {
    const command = ["--git-dir", this.gitDir(sessionId), "--work-tree", cwd, ...IDENTITY, ...args];
    const { stdout } = agentUser()
      ? await runAsAgent("git", command, { env: agentGitEnv(), maxBuffer: 64 * 1024 * 1024 })
      : await run("git", command, { env: gitEnv(), maxBuffer: 64 * 1024 * 1024 });
    return stdout;
  }

  private serial<T>(sessionId: string, work: () => Promise<T>): Promise<T> {
    const next = (this.queues.get(sessionId) ?? Promise.resolve()).catch(() => {}).then(work);
    this.queues.set(sessionId, next);
    return next;
  }
}

/** The branch of the folder's own repository; undefined when the folder is not in one. */
export async function repositoryBranch(cwd: string): Promise<string | undefined> {
  try {
    const { stdout } = await workspaceGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
    return stdout.trim();
  } catch {
    try {
      // A repository without commits yet has no HEAD to name, but is still a repository.
      await workspaceGit(cwd, ["rev-parse", "--git-dir"]);
      return "main";
    } catch {
      return undefined;
    }
  }
}

/** Commits everything in the folder's repository; returns "<short hash> <subject>". */
export async function commitAll(cwd: string, message: string): Promise<string> {
  await workspaceGit(cwd, ["add", "-A"]);
  const staged = await workspaceGit(cwd, ["diff", "--cached", "--quiet"]).then(() => false, () => true);
  if (!staged) throw new Error("nothing to commit");
  // The server's own git identity when it has one; Kervan's otherwise.
  const own = await workspaceGit(cwd, ["config", "user.email"]).then(() => true, () => false);
  await workspaceGit(cwd, ["commit", "--no-verify", "-q", "-m", message], { config: own ? [] : IDENTITY });
  const { stdout } = await workspaceGit(cwd, ["log", "-1", "--format=%h %s"]);
  return stdout.trim();
}
