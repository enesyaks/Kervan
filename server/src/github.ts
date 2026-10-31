import { execFile, spawn, type ChildProcess } from "node:child_process";
import { promisify } from "node:util";
import { log } from "./log.ts";
import { KervanError, type GitHubStatus } from "./protocol.ts";

const run = promisify(execFile);
const HOST = "github.com";
// gh keeps its sign-in under the service user's own home, which is exactly who pushes and opens pull requests.
// Read on every call, so PATH changes (and tests with a stand-in gh) are seen.
const quiet = () => ({ ...process.env, GH_PROMPT_DISABLED: "1", GIT_TERMINAL_PROMPT: "0", NO_COLOR: "1" });

/** The account in `gh auth status` output, in the wording of newer ("account x") and older ("as x") versions. */
export function accountFrom(statusOutput: string): string | undefined {
  return /Logged in to github\.com (?:account|as) ([A-Za-z0-9-]+)/.exec(statusOutput)?.[1];
}

/** The one-time code and address gh prints when it starts a browser sign-in. */
export function deviceCodeFrom(output: string): { code: string; url: string } | undefined {
  const code = /one-time code: ([A-Z0-9]{4}-[A-Z0-9]{4})/.exec(output)?.[1];
  const url = /(https:\/\/github\.com\/login\/device)/.exec(output)?.[1];
  return code && url ? { code, url } : undefined;
}

/**
 * Signs the server in to GitHub with gh's device flow, so pull requests can be opened from a session without anyone
 * touching a terminal: the app shows the code, the user approves it in their own browser, and gh stores the result.
 */
export class GitHubAccess {
  private signingIn?: ChildProcess;

  async status(): Promise<GitHubStatus> {
    try {
      await run("gh", ["--version"], { env: quiet(), timeout: 10_000 });
    } catch {
      return { available: false, signedIn: false, signingIn: false };
    }
    // gh writes the status to stderr in some versions and stdout in others, and exits non-zero when signed out.
    const output = await run("gh", ["auth", "status", "--hostname", HOST], { env: quiet(), timeout: 15_000 }).then(
      ({ stdout, stderr }) => `${stdout}\n${stderr}`,
      (error: { stdout?: string; stderr?: string }) => `${error.stdout ?? ""}\n${error.stderr ?? ""}`,
    );
    const account = accountFrom(output);
    return { available: true, signedIn: account !== undefined, signingIn: this.signingIn !== undefined, ...(account ? { account } : {}) };
  }

  /**
   * Starts a sign-in and resolves with the code to enter at github.com/login/device. `finished` is called once it
   * ends: approved (then git is set to use it), expired or refused.
   */
  connect(finished: (error?: string) => void): Promise<{ code: string; url: string }> {
    this.signingIn?.kill();
    const child = spawn("gh", ["auth", "login", "--hostname", HOST, "--git-protocol", "https", "--web"], {
      env: quiet(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.signingIn = child;
    let output = "";
    return new Promise((resolve, reject) => {
      let answered = false;
      const timer = setTimeout(() => {
        if (answered) return;
        answered = true;
        child.kill();
        reject(new KervanError("bad_message", "gh didn't start a sign-in"));
      }, 20_000);
      const read = (chunk: Buffer) => {
        output += chunk.toString("utf8");
        const device = deviceCodeFrom(output);
        if (device && !answered) {
          answered = true;
          clearTimeout(timer);
          resolve(device);
        }
      };
      child.stdout?.on("data", read);
      child.stderr?.on("data", read);
      child.on("error", (error) => {
        clearTimeout(timer);
        if (this.signingIn === child) this.signingIn = undefined;
        if (!answered) {
          answered = true;
          reject(new KervanError("bad_message", (error as NodeJS.ErrnoException).code === "ENOENT" ? "gh isn't installed on the server" : String(error)));
        }
      });
      child.on("close", async (code) => {
        clearTimeout(timer);
        if (this.signingIn !== child) return; // replaced by a newer sign-in, or cancelled
        this.signingIn = undefined;
        if (!answered) {
          answered = true;
          reject(new KervanError("bad_message", output.trim().split("\n").pop() || "gh stopped before showing a code"));
          return;
        }
        if (code !== 0) {
          finished(output.trim().split("\n").pop() || "the sign-in didn't finish");
          return;
        }
        // Lets git push with the same sign-in.
        await run("gh", ["auth", "setup-git", "--hostname", HOST], { env: quiet(), timeout: 15_000 }).catch((error) =>
          log("warn", "gh auth setup-git failed", { error: String(error) }),
        );
        finished();
      });
    });
  }

  cancel(): void {
    const child = this.signingIn;
    this.signingIn = undefined;
    child?.kill();
  }

  async disconnect(): Promise<void> {
    this.cancel();
    const account = (await this.status()).account;
    if (!account) return;
    await run("gh", ["auth", "logout", "--hostname", HOST, "--user", account], { env: quiet(), timeout: 15_000 }).catch((error) => {
      throw new KervanError("bad_message", `gh auth logout failed: ${(error as { stderr?: string }).stderr?.trim() || String(error)}`);
    });
  }
}
