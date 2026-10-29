import { spawn } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentCommand } from "./agents.ts";
import { log } from "./log.ts";
import type { SessionEventBody } from "./protocol.ts";

/** One running agent conversation. */
export interface AgentProcess {
  /** Resolves with the stop reason once the agent finishes the turn. */
  prompt(text: string): Promise<string>;
  cancel(): Promise<void>;
  close(): void;
  /** Settles when the agent process is gone, whether closed or crashed. */
  readonly exited: Promise<void>;
}

export interface StartOptions {
  command: AgentCommand;
  cwd: string;
  onEvent: (event: SessionEventBody) => void;
}

/**
 * Starts agents. The session layer only sees this interface, so a runner on another
 * machine (M13 nodes) can replace the local one without touching sessions.
 */
export interface AgentRunner {
  start(options: StartOptions): Promise<AgentProcess>;
}

/** Runs an ACP agent as a child process on this machine and talks to it over stdio. */
export class LocalAcpRunner implements AgentRunner {
  async start({ command, cwd, onEvent }: StartOptions): Promise<AgentProcess> {
    const child = spawn(command.command, command.args, {
      cwd,
      env: { ...process.env, ...command.env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    child.stderr.on("data", (chunk: Buffer) => log("debug", "agent stderr", { text: chunk.toString().slice(0, 500) }));

    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    const failedToSpawn = new Promise<never>((_, reject) => child.once("error", reject));
    failedToSpawn.catch(() => {}); // only awaited during startup

    const stream = acp.ndJsonStream(
      Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
      Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>,
    );

    const app = acp
      .client({ name: "kervan" })
      .onNotification("session/update", ({ params }) => {
        const event = toEvent(params.update);
        if (event) onEvent(event);
      })
      .onRequest("session/request_permission", ({ params }) => {
        // No approval UI until M4: refuse, so an unattended agent can't edit files or run commands.
        onEvent({ kind: "permission_auto_rejected", title: params.toolCall.title ?? "araç çağrısı" });
        const reject = params.options.find((o) => o.kind === "reject_once") ?? params.options.find((o) => o.kind === "reject_always");
        return { outcome: reject ? { outcome: "selected", optionId: reject.optionId } : { outcome: "cancelled" } };
      });

    const connection = app.connect(stream);
    const agent = connection.agent;
    const close = () => {
      connection.close();
      child.kill("SIGTERM");
    };

    try {
      await Promise.race([
        agent.request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} }),
        failedToSpawn,
        exited.then(() => Promise.reject(new Error("agent exited during startup"))),
      ]);
      const { sessionId } = await agent.request("session/new", { cwd, mcpServers: [] });

      return {
        exited,
        close,
        async prompt(text) {
          const response = await agent.request("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
          return response.stopReason;
        },
        async cancel() {
          await agent.notify("session/cancel", { sessionId });
        },
      };
    } catch (error) {
      close();
      throw error;
    }
  }
}

function toEvent(update: acp.SessionUpdate): SessionEventBody | null {
  switch (update.sessionUpdate) {
    case "agent_message_chunk":
    case "agent_thought_chunk":
      return update.content.type === "text" ? { kind: update.sessionUpdate, text: update.content.text } : null;
    case "tool_call":
      return {
        kind: "tool_call",
        toolCallId: update.toolCallId,
        title: update.title,
        toolKind: update.kind ?? "other",
        status: update.status ?? "pending",
      };
    case "tool_call_update":
      return {
        kind: "tool_call_update",
        toolCallId: update.toolCallId,
        ...(update.title ? { title: update.title } : {}),
        ...(update.status ? { status: update.status } : {}),
      };
    default:
      return null;
  }
}
