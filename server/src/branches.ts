import { KervanError, type BranchInfo, type ProjectBranches, type SessionInfo } from "./protocol.ts";
import { workspaceGit } from "./safegit.ts";
import { hasCommits } from "./worktree.ts";

/** A project's branches are listed up to this many, newest first; past it `truncated` says so. */
export const MAX_BRANCHES = 300;
/** How many `rev-list` counts run at once. */
const PARALLEL = 8;
const KERVAN = /^kervan\/[a-z0-9][a-z0-9-]*$/;
/** A branch saved from a node that came back after its session moved to the server (see SessionManager.takeover). */
const FROM_NODE = /^(kervan\/[a-z0-9][a-z0-9-]*)-from-(.+)$/;
const FIELDS = ["%(refname)", "%(objectname)", "%(committerdate:iso-strict)", "%(authorname)", "%(subject)"].join("%00");

async function git(repo: string, ...args: string[]): Promise<string> {
  return (await workspaceGit(repo, args, { maxBuffer: 16 * 1024 * 1024, timeout: 30_000 })).stdout;
}

const quiet = (promise: Promise<string>) => promise.then((out) => out.trim(), () => "");

/** What `base...ref` diverged by: commits only on `ref` (ahead) and only on the base (behind). */
async function divergence(repo: string, base: string, ref: string): Promise<{ ahead: number; behind: number }> {
  const out = await quiet(git(repo, "rev-list", "--left-right", "--count", `${base}...${ref}`));
  const [behind, ahead] = out.split(/\s+/).map(Number);
  return { ahead: Number.isFinite(ahead) ? ahead : 0, behind: Number.isFinite(behind) ? behind : 0 };
}

/** The branch the others are measured against: origin's default when it's known, else the folder's own branch. */
async function baseOf(repo: string, current: string | undefined): Promise<{ name: string; ref: string }> {
  const remote = await quiet(git(repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"));
  if (remote.startsWith("origin/")) {
    const local = remote.slice("origin/".length);
    const hasLocal = (await quiet(git(repo, "rev-parse", "--verify", "-q", `refs/heads/${local}^{commit}`))) !== "";
    return hasLocal ? { name: local, ref: `refs/heads/${local}` } : { name: remote, ref: `refs/remotes/${remote}` };
  }
  return current ? { name: current, ref: `refs/heads/${current}` } : { name: "HEAD", ref: "HEAD" };
}

/** Branches checked out in some worktree of the repository, the project folder included. */
async function checkedOut(repo: string): Promise<Set<string>> {
  const out = await quiet(git(repo, "worktree", "list", "--porcelain"));
  const branches = new Set<string>();
  for (const line of out.split("\n")) {
    if (line.startsWith("branch refs/heads/")) branches.add(line.slice("branch refs/heads/".length));
  }
  return branches;
}

async function inParallel<T, R>(items: T[], work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(PARALLEL, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]);
    }
  });
  await Promise.all(workers);
  return results;
}

/**
 * The project's branches as the project page shows them: the user's own and Kervan's (`kervan/…`, each tied to its
 * session), how far each is ahead of and behind the base, and whether it's merged. Branches on origin with no local
 * one are listed too, as git last saw them: nothing is fetched. Undefined when the project isn't a git repository
 * with a commit yet.
 */
export async function projectBranches(projectId: string, repo: string, sessions: SessionInfo[]): Promise<ProjectBranches | undefined> {
  if (!(await hasCommits(repo))) return undefined;
  const current = (await quiet(git(repo, "symbolic-ref", "-q", "--short", "HEAD"))) || undefined;
  const base = await baseOf(repo, current);
  const [refs, merged, worktrees] = await Promise.all([
    git(repo, "for-each-ref", "--sort=-committerdate", `--count=${MAX_BRANCHES + 1}`, `--format=${FIELDS}`, "refs/heads", "refs/remotes/origin"),
    quiet(git(repo, "for-each-ref", `--merged=${base.ref}`, "--format=%(refname)", "refs/heads", "refs/remotes/origin")),
    checkedOut(repo),
  ]);
  const mergedRefs = new Set(merged.split("\n").filter(Boolean));
  const rows = refs.split("\n").filter(Boolean).map((line) => line.split("\0"));
  const truncated = rows.length > MAX_BRANCHES;
  const local = new Set(rows.filter(([ref]) => ref.startsWith("refs/heads/")).map(([ref]) => ref.slice("refs/heads/".length)));
  const byBranch = new Map(sessions.filter((s) => s.branch).map((s) => [s.branch!, s]));

  const kept = rows.slice(0, MAX_BRANCHES).filter(([ref]) => {
    if (ref.startsWith("refs/heads/")) return true;
    const name = ref.slice("refs/remotes/origin/".length);
    return name !== "HEAD" && !local.has(name);
  });
  const branches = await inParallel(kept, async ([ref, head, date, author, ...subject]): Promise<BranchInfo> => {
    const remote = ref.startsWith("refs/remotes/");
    const name = remote ? ref.slice("refs/remotes/".length) : ref.slice("refs/heads/".length);
    const isBase = ref === base.ref;
    const { ahead, behind } = isBase ? { ahead: 0, behind: 0 } : await divergence(repo, base.ref, ref);
    const fromNode = remote ? null : FROM_NODE.exec(name);
    const session = remote ? undefined : byBranch.get(fromNode ? fromNode[1] : name);
    return {
      name,
      head,
      subject: subject.join("\0"),
      date,
      author,
      ahead,
      behind,
      merged: !isBase && mergedRefs.has(ref),
      ...(isBase ? { base: true } : {}),
      ...(name === current && !remote ? { current: true } : {}),
      ...(!remote && name !== current && worktrees.has(name) ? { worktree: true } : {}),
      ...(remote ? { remote: true } : {}),
      ...(!remote && (KERVAN.test(name) || fromNode) ? { kervan: true } : {}),
      ...(session ? { sessionId: session.id } : {}),
      ...(fromNode ? { fromNode: fromNode[2] } : {}),
    };
  });
  return { projectId, base: base.name, ...(current ? { current } : {}), branches, ...(truncated ? { truncated: true } : {}) };
}

/**
 * Deletes Kervan's branches that are merged into the folder's branch and that nothing uses any more: not checked out
 * anywhere, and not the branch of a session that isn't archived. `git branch -d` checks the merge again, so a branch
 * with work of its own is never deleted.
 */
export async function pruneMergedBranches(repo: string, sessions: SessionInfo[]): Promise<{ deleted: string[]; kept: string[] }> {
  if (!(await hasCommits(repo))) throw new KervanError("bad_message", "this project isn't a git repository with a commit yet");
  const current = (await quiet(git(repo, "symbolic-ref", "-q", "--short", "HEAD"))) || undefined;
  if (!current) throw new KervanError("bad_message", "the project folder isn't on a branch, so there's nothing to compare Kervan's branches with");
  const merged = (await quiet(git(repo, "for-each-ref", `--merged=refs/heads/${current}`, "--format=%(refname:short)", "refs/heads/kervan/")))
    .split("\n")
    .filter((name) => KERVAN.test(name) || FROM_NODE.test(name));
  const worktrees = await checkedOut(repo);
  const inUse = new Set(sessions.filter((s) => s.branch && !s.archived).map((s) => s.branch!));
  const deleted: string[] = [];
  const kept: string[] = [];
  for (const name of merged) {
    const owner = FROM_NODE.exec(name)?.[1] ?? name;
    if (name === current || worktrees.has(name) || inUse.has(owner)) {
      kept.push(name);
      continue;
    }
    const gone = await git(repo, "branch", "-d", "--", name).then(() => true, () => false);
    (gone ? deleted : kept).push(name);
  }
  return { deleted, kept };
}
