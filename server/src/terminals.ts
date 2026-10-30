import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { stripAnsi } from "./pty.ts";
import { KervanError } from "./protocol.ts";

/** What a terminal keeps of its output for a client that opens it later. */
const BACKLOG_CHARS = 200_000;
const PTY_HELPER = "import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))";

interface Terminal {
  id: string;
  sessionId: string;
  child: ChildProcess;
  backlog: string;
}

/**
 * A shell per session in the session's folder, for the user (not the agent). It runs in a
 * pseudo-terminal, so `cd`, prompts and Ctrl-C work; colours and cursor moves are removed, so
 * it suits commands, not full-screen programs.
 */
export class TerminalHub {
  private readonly terminals = new Map<string, Terminal>();
  private readonly publish: (message: { type: "terminal.output"; terminalId: string; data: string } | { type: "terminal.exited"; terminalId: string }) => void;

  constructor(publish: TerminalHub["publish"]) {
    this.publish = publish;
  }

  /** The session's terminal, started if it isn't running. */
  open(sessionId: string, cwd: string): { terminalId: string; backlog: string } {
    const running = [...this.terminals.values()].find((t) => t.sessionId === sessionId);
    if (running) return { terminalId: running.id, backlog: running.backlog };
    const child = spawn("python3", ["-c", PTY_HELPER, "bash", "--noprofile", "--norc", "-i"], {
      cwd,
      env: { ...process.env, TERM: "dumb", NO_COLOR: "1", PS1: "\\w $ ", COLUMNS: "120", LINES: "40", PAGER: "cat", GIT_PAGER: "cat" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const terminal: Terminal = { id: randomUUID(), sessionId, child, backlog: "" };
    const output = (chunk: Buffer) => {
      const data = stripAnsi(chunk.toString("utf8"));
      if (data === "") return;
      terminal.backlog = (terminal.backlog + data).slice(-BACKLOG_CHARS);
      this.publish({ type: "terminal.output", terminalId: terminal.id, data });
    };
    child.stdout!.on("data", output);
    child.stderr!.on("data", output);
    child.once("exit", () => {
      this.terminals.delete(terminal.id);
      this.publish({ type: "terminal.exited", terminalId: terminal.id });
    });
    child.once("error", () => this.terminals.delete(terminal.id));
    this.terminals.set(terminal.id, terminal);
    return { terminalId: terminal.id, backlog: "" };
  }

  /** Typed text, as is: a command ends with "\n", Ctrl-C is "\u0003". */
  input(terminalId: string, data: string): void {
    const terminal = this.terminals.get(terminalId);
    if (!terminal) throw new KervanError("bad_message", "this terminal has closed");
    terminal.child.stdin!.write(data);
  }

  close(terminalId: string): void {
    this.terminals.get(terminalId)?.child.kill("SIGHUP");
  }

  closeAll(): void {
    for (const terminal of this.terminals.values()) terminal.child.kill("SIGHUP");
  }
}
