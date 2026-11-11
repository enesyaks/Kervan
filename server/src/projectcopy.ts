import { execFile, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { appendFile, mkdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { EXCLUDES } from "./checkpoints.ts";
import { assertSafeRepository, gitEnv, workspaceGit } from "./safegit.ts";

/**
 * A project worked on from a node. The hub's repository is the source of truth: a node session gets a clone of the
 * project on the node's own disk, works on branch `kervan/…` there, and after every turn its new commits come back to
 * the hub as a bundle that moves the same branch in the project's repository. The project folder's checked-out branch
 * and working tree are never touched, and the branch only ever moves forward, all at once or not at all.
 */

/** What a node announces in its hello when it can hold a project copy. */
export const PROJECTS_FEATURE = "projects";
/** A bundle travels in pieces of this size: well inside one node frame (MAX_NODE_FILE_BYTES). */
export const REPO_CHUNK_BYTES = 8 * 1024 * 1024;
/** A copy or a turn's work larger than this is refused with a message rather than sent. */
export const MAX_REPO_BYTES = 2 * 1024 * 1024 * 1024;
/** Transfer ids name a file on either side, so they're held to this. */
export const TRANSFER_ID = /^[0-9a-f-]{36}$/;

const run = promisify(execFile);
const IDENTITY = ["-c", "user.name=Kervan", "-c", "user.email=kervan@localhost"];
const BRANCH = /^kervan\/[a-z0-9][a-z0-9-]*$/;

export const megabytes = (bytes: number) => `${Math.ceil(bytes / 1024 / 1024)} MB`;

export function assertBranch(branch: string): void {
  if (!BRANCH.test(branch)) throw new Error(`'${branch}' is not a Kervan branch`);
}

/** True when `dir` is a git repository with at least one commit. Synchronous, for checks made while saving a card. */
export function hasCommitsSync(dir: string): boolean {
  try {
    execFileSync("git", ["-C", dir, "rev-parse", "--verify", "-q", "HEAD^{commit}"], { env: gitEnv(), stdio: "ignore", timeout: 10_000 });
    return true;
  } catch {
    return false;
  }
}

async function hubGit(repo: string, ...args: string[]): Promise<string> {
  return (await workspaceGit(repo, args, { maxBuffer: 16 * 1024 * 1024 })).stdout.trim();
}

/** The commit a branch of the hub's repository points at; undefined when there is no such branch. */
export async function branchTip(repo: string, branch: string): Promise<string | undefined> {
  return hubGit(repo, "rev-parse", "--verify", "-q", `refs/heads/${branch}^{commit}`).catch(() => undefined);
}

/** Makes the session's branch at the project's current commit, unless it already exists. The checkout stays as it is. */
export async function ensureBranch(repo: string, branch: string): Promise<string> {
  assertBranch(branch);
  const tip = await branchTip(repo, branch);
  if (tip) return tip;
  await hubGit(repo, "branch", branch, "HEAD");
  return (await branchTip(repo, branch))!;
}

/** Writes the whole branch as a bundle to `file`, for a node to clone. */
export async function bundleBranch(repo: string, branch: string, file: string): Promise<void> {
  assertBranch(branch);
  await hubGit(repo, "bundle", "create", "-q", file, `refs/heads/${branch}`);
}

export type Applied = { moved: false } | { moved: true; head: string };

/**
 * Brings a node's bundle into the hub's repository and moves `branch` from `base` to the bundle's tip. The objects are
 * fetched under a ref of their own first; the branch then moves in one compare-and-swap, and only forward. A bundle
 * that fails to arrive, doesn't apply, or finds the branch moved meanwhile leaves the branch exactly as it was.
 */
export async function applyBundle(repo: string, branch: string, file: string, base: string | undefined): Promise<Applied> {
  assertBranch(branch);
  const incoming = `refs/kervan-incoming/${randomUUID()}`;
  try {
    await hubGit(repo, "fetch", "-q", "--no-tags", "--no-write-fetch-head", file, `+refs/heads/${branch}:${incoming}`);
    const head = await hubGit(repo, "rev-parse", "--verify", `${incoming}^{commit}`);
    if (head === base) return { moved: false };
    if (base) {
      const forward = await hubGit(repo, "merge-base", "--is-ancestor", base, head).then(() => true, () => false);
      if (!forward) throw new Error(`branch ${branch} on the server has commits the node's copy doesn't; nothing was changed`);
    }
    // With no base the branch was deleted here meanwhile: "" has update-ref make it only if it still doesn't exist.
    await hubGit(repo, "update-ref", "-m", "kervan: work from a node", `refs/heads/${branch}`, head, base ?? "");
    return { moved: true, head };
  } finally {
    await hubGit(repo, "update-ref", "-d", incoming).catch(() => {});
  }
}

// The node's side. The agent there runs as the node's own user, but the copy's .git is still the agent's to write,
// so git runs under the same overrides as on the hub, and a copy whose config could run a command is refused.

async function nodeGit(dir: string, args: string[], config: string[] = []): Promise<string> {
  // A project that uses LFS would have the clone ask the bundle for LFS files it can't serve.
  const env = { ...gitEnv(), GIT_LFS_SKIP_SMUDGE: "1" };
  const { stdout } = await run("git", ["-C", dir, ...config, ...args], { env, maxBuffer: 16 * 1024 * 1024 });
  return stdout.trim();
}

/** Where a transfer's bundle waits, under the node's (or hub's) own transfers folder. */
export function transferFile(root: string, id: string): string {
  if (!TRANSFER_ID.test(id)) throw new Error("bad transfer id");
  return join(root, ".kervan-transfers", id);
}

/** Adds one piece to a transfer; `offset` must be where the file ends now, so a lost or repeated piece is caught. */
export async function appendPiece(file: string, offset: number, data: Buffer): Promise<number> {
  const sizeNow = existsSync(file) ? (await stat(file)).size : 0;
  if (offset !== sizeNow) throw new Error(`transfer out of step: expected a piece at ${sizeNow}, got ${offset}`);
  if (offset + data.length > MAX_REPO_BYTES) throw new Error(`a project copy can be at most ${megabytes(MAX_REPO_BYTES)}`);
  await mkdir(dirname(file), { recursive: true, mode: 0o770 });
  await appendFile(file, data, { mode: 0o640 });
  return offset + data.length;
}

/** The commit the copy in `dir` is on; undefined when there is no copy there yet. */
export async function copyHead(dir: string): Promise<string | undefined> {
  if (!existsSync(join(dir, ".git"))) return undefined;
  return nodeGit(dir, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]).catch(() => undefined);
}

/** Clones the bundle into `dir` (missing or empty), on `branch`, with no remote: it only talks to the hub through Kervan. */
export async function cloneBundle(dir: string, file: string, branch: string): Promise<string> {
  assertBranch(branch);
  await mkdir(dirname(dir), { recursive: true });
  await nodeGit(dirname(dir), ["clone", "-q", "--no-hardlinks", "--branch", branch, file, dir]);
  await nodeGit(dir, ["remote", "remove", "origin"]);
  // Rebuilt or private files stay out of the branch, as they stay out of checkpoints; so do the user's uploads.
  await appendFile(join(dir, ".git", "info", "exclude"), `\n${[...EXCLUDES, "/uploads/"].join("\n")}\n`);
  return nodeGit(dir, ["rev-parse", "HEAD"]);
}

export type Committed = { head: string; changed: false } | { head: string; changed: true; size: number };

/**
 * Commits what the agent left uncommitted and, if its branch moved past `base` (what the hub has), writes the new
 * commits as a bundle to `file`. A turn that changed nothing writes nothing.
 */
export async function commitTurn(dir: string, branch: string, base: string | undefined, message: string, file: string): Promise<Committed> {
  assertBranch(branch);
  if (!existsSync(join(dir, ".git"))) throw new Error("this node has no copy of the project for this session");
  await assertSafeRepository(dir);
  await nodeGit(dir, ["add", "-A"]);
  const staged = await nodeGit(dir, ["diff", "--cached", "--quiet"]).then(() => false, () => true);
  if (staged) {
    // The node's own git identity when it has one; Kervan's otherwise.
    const own = await nodeGit(dir, ["config", "user.email"]).then(() => true, () => false);
    await nodeGit(dir, ["commit", "--no-verify", "-q", "-m", message], own ? [] : IDENTITY);
  }
  const head = await nodeGit(dir, ["rev-parse", "--verify", `refs/heads/${branch}^{commit}`]);
  if (head === base) return { head, changed: false };
  // Only what the hub lacks travels; if the hub's tip is unknown here, the whole branch does (and the hub refuses it).
  const known = base ? await nodeGit(dir, ["cat-file", "-e", `${base}^{commit}`]).then(() => true, () => false) : false;
  await mkdir(dirname(file), { recursive: true, mode: 0o770 });
  await nodeGit(dir, ["bundle", "create", "-q", file, `refs/heads/${branch}`, ...(known ? [`^${base}`] : [])]);
  const { size } = await stat(file);
  if (size > MAX_REPO_BYTES) throw new Error(`this turn's work is ${megabytes(size)}; at most ${megabytes(MAX_REPO_BYTES)} can go to the server at once`);
  return { head, changed: true, size };
}
