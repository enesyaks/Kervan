import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);
// Kervan's own commits (snapshots, merges) need an identity even where the kervan user has none.
const IDENTITY = ["-c", "user.name=Kervan", "-c", "user.email=kervan@localhost"];
const MAX_PATCH_CHARS = 20_000;

async function git(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await run("git", ["-C", cwd, ...IDENTITY, ...args], { maxBuffer: 16 * 1024 * 1024 });
  return stdout;
}

/** True when `dir` is a git repository with at least one commit to branch from. */
export async function hasCommits(dir: string): Promise<boolean> {
  try {
    await git(dir, "rev-parse", "--verify", "HEAD");
    return true;
  } catch {
    return false;
  }
}

/** A branch name git accepts, readable in `git branch`: kervan/<name>-<id>. */
export function branchName(name: string, id: string): string {
  const slug = name
    .toLocaleLowerCase("tr")
    .replace(/ı/g, "i")
    .normalize("NFD")
    .replace(/\p{M}+/gu, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  return `kervan/${slug || "helper"}-${id.slice(0, 8)}`;
}

/** A new worktree at `path` on a new branch from the repo's current HEAD. */
export async function addWorktree(repo: string, path: string, branch: string): Promise<void> {
  await git(repo, "worktree", "add", "-b", branch, path, "HEAD");
}

/** Puts a removed worktree back, on the branch it left behind. */
export async function restoreWorktree(repo: string, path: string, branch: string): Promise<void> {
  await git(repo, "worktree", "add", path, branch);
}

/**
 * Takes a session's worktree away but keeps its work: anything uncommitted is committed to its branch first, and the
 * branch stays, so the worktree can come back. Ignored files (build output, dependencies) go with the folder.
 */
export async function removeWorktree(repo: string, worktree: string, label: string): Promise<void> {
  await snapshot(worktree, `Kervan: ${label} (kept when its worktree was removed)`);
  await git(repo, "worktree", "remove", "--force", worktree);
}

/** Commits whatever the helper left uncommitted, so its branch holds all of its work. */
async function snapshot(worktree: string, message: string): Promise<void> {
  await git(worktree, "add", "-A");
  try {
    await git(worktree, "diff", "--cached", "--quiet");
  } catch {
    await git(worktree, "commit", "--no-verify", "-m", message);
  }
}

/** What the branch changed since it left the repo's current branch, uncommitted work included. */
export async function branchDiff(repo: string, worktree: string, branch: string, label: string): Promise<{ stat: string; patch: string }> {
  await snapshot(worktree, `Kervan: ${label} (work in progress)`);
  const stat = (await git(repo, "diff", "--stat", `HEAD...${branch}`)).trim();
  const patch = await git(repo, "diff", `HEAD...${branch}`);
  return {
    stat: stat || "no changes",
    patch: patch.length > MAX_PATCH_CHARS ? `${patch.slice(0, MAX_PATCH_CHARS)}\n… (cut short)` : patch,
  };
}

export type MergeResult = { merged: true; stat: string } | { merged: false; conflicts: string[]; message: string };

/**
 * Merges the helper's branch into the repo's current branch. On a conflict nothing is left half-done:
 * the merge is aborted and the conflicting files are reported so the lead can sort them out.
 */
export async function mergeBranch(repo: string, worktree: string, branch: string, label: string): Promise<MergeResult> {
  await snapshot(worktree, `Kervan: ${label}`);
  const before = (await git(repo, "rev-parse", "HEAD")).trim();
  try {
    await git(repo, "merge", "--no-ff", "--no-edit", "-m", `Kervan: merge ${label}`, branch);
  } catch (error) {
    const conflicts = (await git(repo, "diff", "--name-only", "--diff-filter=U").catch(() => ""))
      .split("\n")
      .filter(Boolean);
    await git(repo, "merge", "--abort").catch(() => {});
    const message = error instanceof Error && "stderr" in error ? String((error as { stderr: unknown }).stderr).trim() : String(error);
    return { merged: false, conflicts, message: message || "merge failed" };
  }
  const stat = (await git(repo, "diff", "--stat", before, "HEAD")).trim();
  return { merged: true, stat: stat || "no changes" };
}
