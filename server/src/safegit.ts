import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { cleanEnv } from "./agentenv.ts";
import { KervanError } from "./protocol.ts";

const run = promisify(execFile);

/**
 * An agent can write to the repository in its folder, .git/config and .git/hooks included, and git runs commands named
 * there: a hook, an fsmonitor, a clean filter. So when the server runs git in such a folder, what's named there mustn't
 * run. Settings that can be overridden are, for every git in the process tree (gh's too, hence the environment rather
 * than -c); those that can't be are refused below.
 */
const OVERRIDES: [string, string][] = [
  ["core.hooksPath", "/dev/null"],
  ["core.fsmonitor", "false"],
  ["commit.gpgSign", "false"],
  ["tag.gpgSign", "false"],
  ["protocol.ext.allow", "never"],
];

/**
 * Settings in a repository's own config that make git run a command or send its traffic elsewhere, and can't be switched
 * off from outside: their names contain the user's own words (filter.<name>.clean), or a value here would replace the
 * server's own. Written as a list of what git can do; unknown settings pass, so ordinary tools' keys don't block commits.
 */
const REFUSED = [
  /^filter\..+\.(clean|smudge|process)$/i,
  /^diff\.external$/i,
  /^diff\..+\.(command|textconv)$/i,
  /^merge\..+\.driver$/i,
  /^trailer\..+\.(cmd|command)$/i,
  /^core\.(sshcommand|askpass|gitproxy|alternaterefscommand|worktree)$/i,
  /^credential\./i,
  /^url\./i,
  /^http\./i,
  /^protocol\./i,
  /^remote\..+\.(pushurl|proxy|receivepack|uploadpack|vcs)$/i,
];

// Git LFS's own filter, exactly as `git lfs install --local` writes it, is the one common and harmless case.
const LFS_FILTER: Record<string, string> = {
  "filter.lfs.clean": "git-lfs clean -- %f",
  "filter.lfs.smudge": "git-lfs smudge -- %f",
  "filter.lfs.process": "git-lfs filter-process",
};

/** The commands that can reach those settings; the rest only read refs and names, and work on any repository. */
const RUNS_SETTINGS = new Set(["add", "commit", "checkout", "worktree", "merge", "diff", "push", "fetch", "pull", "status"]);

/** The environment for git and gh in a workspace: nothing secret but GitHub's own, and the overrides above. */
export function gitEnv(): NodeJS.ProcessEnv {
  const env = cleanEnv(["GH_*", "GITHUB_*"]);
  env.GIT_TERMINAL_PROMPT = "0"; // never wait on a password prompt: the server has no one to type it
  env.GH_PROMPT_DISABLED = "1";
  env.GIT_CONFIG_COUNT = String(OVERRIDES.length);
  OVERRIDES.forEach(([key, value], index) => {
    env[`GIT_CONFIG_KEY_${index}`] = key;
    env[`GIT_CONFIG_VALUE_${index}`] = value;
  });
  return env;
}

/** The first setting in the repository's own config that Kervan won't run git under, if any. */
export function refusedSetting(listing: string): string | undefined {
  // `git config --list --show-scope -z`: scope NUL key LF value NUL, with no LF when a key has no value.
  const fields = listing.split("\0");
  for (let i = 0; i + 1 < fields.length; i += 2) {
    const scope = fields[i];
    if (scope !== "local" && scope !== "worktree") continue;
    const newline = fields[i + 1].indexOf("\n");
    const key = newline < 0 ? fields[i + 1] : fields[i + 1].slice(0, newline);
    const value = newline < 0 ? "" : fields[i + 1].slice(newline + 1);
    if (LFS_FILTER[key.toLowerCase()] === value) continue;
    if (REFUSED.some((pattern) => pattern.test(key))) return key;
  }
  return undefined;
}

/** Throws when the repository at `cwd` has settings of its own that could run a command under Kervan's git. */
export async function assertSafeRepository(cwd: string): Promise<void> {
  const { stdout } = await run("git", ["-C", cwd, "config", "--list", "--show-scope", "-z"], { env: gitEnv(), maxBuffer: 4 * 1024 * 1024 });
  const setting = refusedSetting(stdout);
  if (setting) {
    throw new KervanError(
      "bad_message",
      `this repository's .git/config sets ${setting}, which can run a command or redirect git, and an agent could have put it there. ` +
        "Kervan won't run git here until it's removed.",
    );
  }
}

/** Runs git in a workspace, safely: `config` (`-c` pairs) goes before the command. */
export async function workspaceGit(
  cwd: string,
  args: string[],
  options: { config?: string[]; timeout?: number; maxBuffer?: number } = {},
): Promise<{ stdout: string; stderr: string }> {
  if (RUNS_SETTINGS.has(args[0])) await assertSafeRepository(cwd);
  return run("git", ["-C", cwd, ...(options.config ?? []), ...args], {
    env: gitEnv(),
    maxBuffer: options.maxBuffer ?? 16 * 1024 * 1024,
    ...(options.timeout ? { timeout: options.timeout } : {}),
  });
}
