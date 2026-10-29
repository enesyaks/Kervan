import { spawn } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentCommand } from "./agents.ts";
import { log } from "./log.ts";
import type { PermissionChoice, SessionEventBody } from "./protocol.ts";

/** One running agent conversation. */
export interface AgentProcess {
  /** Resolves with the stop reason once the agent finishes the turn. */
  prompt(text: string): Promise<string>;
  cancel(): Promise<void>;
  close(): void;
  /** Settles when the agent process is gone, whether closed or crashed. */
  readonly exited: Promise<void>;
}

export interface PermissionRequest {
  title: string;
  toolKind: string;
  /** The command to run or the paths touched, when the agent says. */
  detail?: string;
  options: PermissionChoice[];
}

/** The chosen option, or `null` when the request was cancelled. */
export type PermissionDecision = string | null;

export interface StartOptions {
  command: AgentCommand;
  cwd: string;
  onEvent: (event: SessionEventBody) => void;
  /** Resolves once the user answers; may stay pending for as long as the user is away. */
  onPermission: (request: PermissionRequest) => Promise<PermissionDecision>;
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
  async start({ command, cwd, onEvent, onPermission }: StartOptions): Promise<AgentProcess> {
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
      .onRequest("session/request_permission", async ({ params }) => {
        const optionId = await onPermission({
          title: params.toolCall.title ?? "Araç çağrısı",
          toolKind: params.toolCall.kind ?? "other",
          detail: describe(params.toolCall),
          options: params.options.map(({ optionId, name, kind }) => ({ optionId, name, kind })),
        });
        return { outcome: optionId ? { outcome: "selected", optionId } : { outcome: "cancelled" } };
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

/** What the user needs to judge a request: the shell command, else the files involved. */
function describe(toolCall: acp.ToolCallUpdate): string | undefined {
  const input = toolCall.rawInput;
  if (input && typeof input === "object" && "command" in input && typeof input.command === "string") {
    return input.command;
  }
  const paths = toolCall.locations?.map((location) => location.path) ?? [];
  return paths.length > 0 ? paths.join("\n") : undefined;
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
