import { execFile, spawn, type ChildProcess } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { cleanEnv } from "./agentenv.ts";
import { KervanError } from "./protocol.ts";

const run = promisify(execFile);
const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The builtin agents that can sign in with an account (a subscription) instead of an API key. */
export const ACCOUNT_AGENTS = ["claude", "codex"] as const;
export type AccountAgent = (typeof ACCOUNT_AGENTS)[number];
export const isAccountAgent = (id: string): id is AccountAgent => (ACCOUNT_AGENTS as readonly string[]).includes(id);

/**
 * How a sign-in goes on in the user's browser: open `url`; for Codex enter `code` there, for Claude bring back the
 * code the page shows (`needsCode`).
 */
export interface AgentLoginStart {
  agent: AccountAgent;
  url: string;
  code?: string;
  needsCode: boolean;
}

/** The Claude CLI that came with the Agent SDK (in a per-platform package), so nothing has to be installed. */
function bundledClaude(): string | undefined {
  const scope = join(serverRoot, "node_modules/@anthropic-ai");
  if (!existsSync(scope)) return undefined;
  for (const name of readdirSync(scope)) {
    const binary = join(scope, name, "claude");
    if (name.startsWith("claude-agent-sdk-") && existsSync(binary)) return binary;
  }
  return undefined;
}

/** The CLI each agent signs in with. Read on every call, so tests can point it at a stand-in. */
function cli(agent: AccountAgent): string {
  if (agent === "claude") return process.env.KERVAN_CLAUDE_CLI || bundledClaude() || "claude";
  return process.env.KERVAN_CODEX_CLI || join(serverRoot, "node_modules/.bin/codex");
}

// No browser on a server: the CLIs print the address instead, and the app opens it on the Mac.
const quiet = () => ({ ...cleanEnv(), BROWSER: "false", NO_COLOR: "1", TERM: "dumb" });
const plain = (text: string) => text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");

// The app opens this address on the user's Mac, so only Anthropic's own sign-in pages count.
const CLAUDE_LOGIN_HOSTS = new Set(["claude.com", "claude.ai", "console.anthropic.com", "platform.claude.com"]);
const hostOf = (url: string) => {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
};

/** The sign-in page and code a CLI printed, once it has printed them. */
export function loginPromptFrom(agent: AccountAgent, output: string): Omit<AgentLoginStart, "agent"> | undefined {
  const text = plain(output);
  if (agent === "claude") {
    const url = /(https:\/\/\S+\/oauth\/authorize\?\S+)/.exec(text)?.[1];
    return url && CLAUDE_LOGIN_HOSTS.has(hostOf(url)) ? { url, needsCode: true } : undefined;
  }
  const url = /(https:\/\/auth\.openai\.com\/\S*device\S*)/.exec(text)?.[1];
  const code = /\b([A-Z0-9]{4}-[A-Z0-9]{4,6})\b/.exec(text)?.[1];
  return url && code ? { url, code, needsCode: false } : undefined;
}

const lastLine = (output: string) => plain(output).trim().split("\n").filter(Boolean).pop();

/**
 * Signs builtin agents in with the user's own account, from the app: the server runs the agent's login, the user
 * signs in in their browser on the Mac, and the CLI keeps the result in the service user's home on the server.
 * Nothing about the login reaches the app; only whether it worked.
 */
export class AgentLogin {
  private readonly running = new Map<AccountAgent, ChildProcess>();

  isSigningIn(agent: string): boolean {
    return isAccountAgent(agent) && this.running.has(agent);
  }

  /** Starts a sign-in; `finished` is called when it ends: signed in, or why not. */
  start(agent: string, finished: (error?: string) => void): Promise<AgentLoginStart> {
    if (!isAccountAgent(agent)) throw new KervanError("bad_message", `${agent} can't sign in with an account; give it a key`);
    this.cancel(agent);
    const args = agent === "claude" ? ["auth", "login", "--claudeai"] : ["login", "--device-auth"];
    const child = spawn(cli(agent), args, { env: quiet(), stdio: ["pipe", "pipe", "pipe"] });
    this.running.set(agent, child);
    let output = "";
    return new Promise((resolve, reject) => {
      let answered = false;
      const timer = setTimeout(() => {
        if (answered) return;
        answered = true;
        child.kill();
        reject(new KervanError("bad_message", "the agent didn't start a sign-in"));
      }, 30_000);
      const read = (chunk: Buffer) => {
        output += chunk.toString("utf8");
        const prompt = answered ? undefined : loginPromptFrom(agent, output);
        if (prompt) {
          answered = true;
          clearTimeout(timer);
          resolve({ agent, ...prompt });
        }
      };
      child.stdout?.on("data", read);
      child.stderr?.on("data", read);
      child.stdin?.on("error", () => {}); // the CLI may close its input first
      child.on("error", (error) => {
        clearTimeout(timer);
        if (this.running.get(agent) === child) this.running.delete(agent);
        if (answered) return;
        answered = true;
        const missing = (error as NodeJS.ErrnoException).code === "ENOENT";
        reject(new KervanError("bad_message", missing ? `the ${agent} command isn't on the server` : String(error)));
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        if (this.running.get(agent) !== child) return; // replaced by a newer sign-in, or cancelled
        this.running.delete(agent);
        if (!answered) {
          answered = true;
          reject(new KervanError("bad_message", lastLine(output) || "the agent stopped before showing a sign-in page"));
          return;
        }
        finished(code === 0 ? undefined : lastLine(output) || "the sign-in didn't finish");
      });
    });
  }

  /** Claude's code from the page the user signed in on. */
  submitCode(agent: string, code: string): void {
    const child = isAccountAgent(agent) ? this.running.get(agent) : undefined;
    if (!child) throw new KervanError("bad_message", "no sign-in is waiting for a code; start again");
    const trimmed = code.trim();
    if (!trimmed || trimmed.length > 2000 || /[\r\n\0]/.test(trimmed)) throw new KervanError("bad_message", "that doesn't look like a sign-in code");
    child.stdin?.write(`${trimmed}\n`);
  }

  cancel(agent: string): void {
    if (!isAccountAgent(agent)) return;
    const child = this.running.get(agent);
    this.running.delete(agent);
    child?.kill();
  }

  async signOut(agent: string): Promise<void> {
    if (!isAccountAgent(agent)) throw new KervanError("bad_message", `${agent} has no account sign-in`);
    this.cancel(agent);
    const args = agent === "claude" ? ["auth", "logout"] : ["logout"];
    await run(cli(agent), args, { env: quiet(), timeout: 20_000 }).catch((error: { stderr?: string }) => {
      throw new KervanError("bad_message", `signing out failed: ${error.stderr?.trim() || String(error)}`);
    });
  }
}
