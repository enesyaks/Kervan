import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { commitAll, repositoryBranch } from "./checkpoints.ts";
import { KervanError, type PullRequestInfo } from "./protocol.ts";
import { gitEnv, workspaceGit } from "./safegit.ts";
import { branchName } from "./worktree.ts";

const run = promisify(execFile);
async function git(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await workspaceGit(cwd, args, { timeout: 90_000 });
  return stdout.trim();
}

function stderrOf(error: unknown): string {
  if (error instanceof Error && "stderr" in error) return String((error as { stderr: unknown }).stderr).trim();
  return error instanceof Error ? error.message : String(error);
}

/** https://github.com/<owner>/<repo> for a GitHub remote, in either the SSH or the HTTPS form. */
export function githubRepoURL(remote: string): string | undefined {
  const match = /^(?:git@github\.com:|ssh:\/\/git@github\.com\/|https:\/\/(?:[^@/]+@)?github\.com\/)([^/]+)\/(.+?)(?:\.git)?\/?$/.exec(remote.trim());
  return match ? `https://github.com/${match[1]}/${match[2]}` : undefined;
}

/** https, ssh or scp-style: anything else is a path on this machine, or a transport Kervan doesn't use. */
export function isNetworkRemote(remote: string): boolean {
  const value = remote.trim();
  return /^(https|ssh):\/\//i.test(value) || /^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^/]/.test(value);
}

/** The remote's default branch as git knows it, else main or master, whichever exists. */
async function baseBranch(cwd: string): Promise<string> {
  const head = await git(cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").catch(() => "");
  if (head.startsWith("origin/")) return head.slice("origin/".length);
  for (const name of ["main", "master"]) {
    if (await git(cwd, "rev-parse", "--verify", "--quiet", `refs/remotes/origin/${name}`).then(() => true, () => false)) return name;
  }
  return "main";
}

/**
 * Puts the session's work up for review: moves it off the base branch onto its own branch, commits what is
 * left, pushes, and opens a pull request with gh when the server has it. Without gh (or when it can't),
 * the answer carries GitHub's compare page, where the pull request is one click away.
 */
export async function openPullRequest(
  cwd: string,
  request: { title: string; body: string; sessionId: string },
): Promise<PullRequestInfo> {
  const current = await repositoryBranch(cwd);
  if (current === undefined) throw new KervanError("bad_message", "this folder is not a git repository");
  const remote = await git(cwd, "remote", "get-url", "origin").catch(() => "");
  if (!remote) throw new KervanError("bad_message", "this repository has no 'origin' remote to push to");

  // Pushing to a folder runs that repository's own hooks as this server, and an agent can change where origin points.
  if (!isNetworkRemote(remote) && !process.env.KERVAN_ALLOW_LOCAL_REMOTES) {
    throw new KervanError("bad_message", `'origin' points at a folder on this server (${remote}), and Kervan only pushes over the network`);
  }

  const base = await baseBranch(cwd);
  let branch = current;
  if (current === base || current === "HEAD") {
    // Uncommitted changes come along to the new branch; the base branch stays as it was.
    branch = branchName(request.title, request.sessionId);
    await git(cwd, "checkout", "-b", branch).catch((error) => {
      throw new KervanError("bad_message", `couldn't create branch ${branch}: ${stderrOf(error)}`);
    });
  }
  await commitAll(cwd, request.title).catch((error) => {
    if (!(error instanceof Error && error.message === "nothing to commit")) {
      throw new KervanError("bad_message", `git commit failed: ${stderrOf(error)}`);
    }
  });

  const ahead = await git(cwd, "rev-list", "--count", `origin/${base}..HEAD`).catch(() => "1");
  if (ahead === "0") throw new KervanError("bad_message", `nothing to propose: ${branch} has no commits that ${base} doesn't have`);

  await git(cwd, "push", "-u", "origin", branch).catch((error) => {
    throw new KervanError(
      "bad_message",
      `pushing ${branch} failed: ${stderrOf(error)}. The server needs push access to this repository, ` +
        "for example by connecting it to GitHub in the app: Settings › General › GitHub.",
    );
  });

  const created = await run("gh", ["pr", "create", "--title", request.title, "--body", request.body, "--base", base, "--head", branch], {
    cwd,
    env: gitEnv(),
    timeout: 60_000,
  }).then(
    ({ stdout }) => stdout.trim().split("\n").pop(),
    () => undefined,
  );
  if (created?.startsWith("https://")) return { branch, base, url: created, created: true };

  const repo = githubRepoURL(remote);
  // Slashes stay as they are: kervan/fix-… is a path GitHub reads, %2F is not always.
  const path = (name: string) => name.split("/").map(encodeURIComponent).join("/");
  const url = repo ? `${repo}/compare/${path(base)}...${path(branch)}?expand=1` : undefined;
  return { branch, base, created: false, ...(url ? { url } : {}) };
}
