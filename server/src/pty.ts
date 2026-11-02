import { agentEnv } from "./agentenv.ts";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { AgentProcess, StartOptions } from "./runner.ts";

/** Quiet time after output that ends a turn, unless the agent sets `quietMs`. */
export const DEFAULT_QUIET_MS = 2000;
/** A turn with no output at all ends after this long. */
const SILENT_TURN_MS = 60_000;

/** Removes terminal control sequences (colours, cursor moves, titles) and carriage returns. */
export function stripAnsi(text: string): string {
  return text
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "") // OSC: window titles, links
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "") // CSI: colours, cursor, erase
    .replace(/\x1b[@-Z\\-_]/g, "")
    .replace(/\r/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
}

// Python's standard pty module gives the command a real terminal on both Linux and macOS without a native
// Node module; unlike `script`, it works when its own input is a pipe.
const PTY_HELPER = "import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))";

function underTerminal(command: string, args: string[]): [string, string[]] {
  return ["python3", ["-c", PTY_HELPER, command, ...args]];
}

/**
 * The fallback for command-line agents that don't speak ACP: they run in a pseudo-terminal, each message
 * is typed as a line, and whatever they print comes back as the answer. A turn ends once the agent has
 * been quiet for `quietMs`. There is no resume and no permission prompt: such agents ask in their output,
 * and the user answers with the next message.
 */
export async function startPty({ command, cwd, onEvent }: StartOptions): Promise<AgentProcess> {
  const [program, args] = underTerminal(command.command, command.args);
  const child = spawn(program, args, {
    cwd,
    env: { ...agentEnv(command), TERM: "dumb", NO_COLOR: "1", COLUMNS: "120", LINES: "40" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  const quietMs = command.quietMs ?? DEFAULT_QUIET_MS;

  let turn: { echo: string; heard: boolean; timer?: NodeJS.Timeout; end: (reason: string) => void } | undefined;
  const settle = (ms: number) => {
    if (!turn) return;
    clearTimeout(turn.timer);
    turn.timer = setTimeout(() => turn?.end("end_turn"), ms);
  };

  const onOutput = (chunk: Buffer) => {
    let text = stripAnsi(chunk.toString("utf8"));
    if (turn?.echo) {
      // The terminal echoes what was typed once; that is the user's message, not the answer.
      const echoed = text.indexOf(turn.echo);
      if (echoed !== -1) {
        text = text.slice(echoed + turn.echo.length).replace(/^\n/, "");
        turn.echo = "";
      }
    }
    if (text === "") return;
    if (turn) {
      turn.heard = true;
      settle(quietMs);
    }
    onEvent({ kind: "agent_message_chunk", text });
  };
  child.stdout.on("data", onOutput);
  child.stderr.on("data", onOutput);

  // Fail like an ACP agent that can't start: the command must still be running a moment later.
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, 300);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    exited.then(() => {
      clearTimeout(timer);
      reject(new Error(`'${command.command}' exited right away`));
    });
  });

  return {
    sessionId: `pty-${randomUUID()}`,
    exited,
    close() {
      turn?.end("cancelled");
      child.kill("SIGTERM");
    },
    prompt(text, files = []) {
      const line = [text.replace(/\s*\n\s*/g, " ").trim(), ...files].join(" ");
      return new Promise<string>((resolve, reject) => {
        exited.then(() => reject(new Error("the terminal agent exited")));
        turn = {
          echo: line,
          heard: false,
          end: (reason) => {
            clearTimeout(turn?.timer);
            turn = undefined;
            resolve(reason);
          },
        };
        settle(SILENT_TURN_MS);
        child.stdin.write(`${line}\n`);
      });
    },
    async cancel() {
      child.stdin.write("\x03"); // Ctrl-C, as a person at the terminal would
      turn?.end("cancelled");
    },
  };
}
