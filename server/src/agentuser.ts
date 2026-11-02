import { execFile, execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Agents, their terminals and git in their folders run as a second system user, away from the server's secrets, where
 * setup made one (KERVAN_AGENT_USER; see docs/plans/agent-isolation.md). Elsewhere, on a Mac or in development, they
 * run as this process. The server only reaches that user through bin/run-agent, the one thing sudo allows it.
 */
export const agentUser = (): string | undefined => process.env.KERVAN_AGENT_USER || undefined;

const WRAPPER = join(dirname(fileURLToPath(import.meta.url)), "../bin/run-agent");

/** What bin/run-agent reads first on stdin: a count, then NAME=<base64 value> lines. Not in `ps`, unlike arguments. */
export function envPrelude(env: NodeJS.ProcessEnv): string {
  const lines = Object.entries(env)
    .filter(([name, value]) => value !== undefined && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name))
    .map(([name, value]) => `${name}=${Buffer.from(value as string).toString("base64")}`);
  return `${lines.length}\n${lines.map((line) => `${line}\n`).join("")}`;
}

const sudoArgs = (user: string, program: string, args: readonly string[]) => ["-n", "-u", user, WRAPPER, program, ...args];
// sudo itself gets nothing of the server's: only what it takes to be found.
const sudoEnv = () => ({ PATH: process.env.PATH ?? "/usr/bin:/bin" });

/** `spawn` for something an agent runs, with all three streams as pipes. */
export function spawnAgent(program: string, args: readonly string[], options: { env: NodeJS.ProcessEnv; cwd?: string }): ChildProcessWithoutNullStreams {
  const user = agentUser();
  if (!user) return spawn(program, args, { ...options, stdio: ["pipe", "pipe", "pipe"] });
  const child = spawn("sudo", sudoArgs(user, program, args), { ...options, env: sudoEnv(), stdio: ["pipe", "pipe", "pipe"] });
  child.stdin.write(envPrelude(options.env));
  return child;
}

/** `execFile` as the agent user; only called when there is one. */
export function runAsAgent(
  program: string,
  args: readonly string[],
  options: { env: NodeJS.ProcessEnv; cwd?: string; timeout?: number; maxBuffer?: number },
): Promise<{ stdout: string; stderr: string }> {
  const user = agentUser();
  if (!user) throw new Error("no agent user on this server");
  return new Promise((resolve, reject) => {
    const child = execFile(
      "sudo",
      sudoArgs(user, program, args),
      { env: sudoEnv(), maxBuffer: options.maxBuffer ?? 16 * 1024 * 1024, ...(options.cwd ? { cwd: options.cwd } : {}), ...(options.timeout ? { timeout: options.timeout } : {}) },
      (error, stdout, stderr) => (error ? reject(Object.assign(error, { stdout, stderr })) : resolve({ stdout, stderr })),
    );
    child.stdin?.on("error", () => {}); // a program may exit before reading it all
    child.stdin?.end(envPrelude(options.env));
  });
}

/** Whether a file exists under the agent user's home, which the server can't look into itself. */
export function agentHasFile(relativePath: string): boolean {
  const user = agentUser();
  if (!user) return false;
  try {
    execFileSync("sudo", sudoArgs(user, "bash", ["-c", 'test -e "$HOME/$1"', "_", relativePath]), {
      env: sudoEnv(),
      input: envPrelude({ PATH: process.env.PATH }),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 10_000,
    });
    return true;
  } catch {
    return false;
  }
}

/** A scratch folder an agent can start in, to try it out. */
export function probeFolder(): string {
  if (!agentUser()) return mkdtempSync(join(tmpdir(), "kervan-probe-"));
  // Group-writable from the start: the service may not chmod setgid bits, and the folder inherits that one from its parent.
  const folder = join(process.env.KERVAN_WORKSPACES_DIR ?? tmpdir(), `.probe-${randomUUID()}`);
  mkdirSync(folder, { mode: 0o770 });
  return folder;
}
