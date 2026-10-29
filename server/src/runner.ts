import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentCommand } from "./agents.ts";
import { log } from "./log.ts";
import type { PermissionChoice, SessionEventBody } from "./protocol.ts";

/** One running agent conversation. */
export interface AgentProcess {
  /**
   * Resolves with the stop reason once the agent finishes the turn. `files` are absolute paths;
   * `preface` is context for the agent that the user didn't type (e.g. the session's skills).
   */
  prompt(text: string, files?: string[], preface?: string): Promise<string>;
  cancel(): Promise<void>;
  close(): void;
  /** Settles when the agent process is gone, whether closed or crashed. */
  readonly exited: Promise<void>;
  /** The agent's own session id; pass it back as `resumeSessionId` to continue after a restart. */
  readonly sessionId: string;
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
  /** Continue this earlier agent session instead of starting a new one. */
  resumeSessionId?: string;
  /** Called with the agent's MCP capabilities; returns the servers to pass to session/new or resume. */
  mcpServers?: (supportsHttp: boolean) => acp.McpServer[];
}

/**
 * Starts agents. The session layer only sees this interface, so a runner on another
 * machine (M13 nodes) can replace the local one without touching sessions.
 */
export interface AgentRunner {
  start(options: StartOptions): Promise<AgentProcess>;
}

/**
 * Starts the agent once in a scratch folder (initialize, auth, session/new) and stops it:
 * proof that an agent added from the app actually works here.
 */
export async function probeAgent(runner: AgentRunner, command: AgentCommand, timeoutMs = 30_000): Promise<void> {
  const cwd = mkdtempSync(join(tmpdir(), "kervan-probe-"));
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no answer within ${timeoutMs / 1000} s`)), timeoutMs);
  });
  const started = runner.start({ command, cwd, onEvent: () => {}, onPermission: async () => null });
  try {
    const agent = await Promise.race([started, timeout]);
    agent.close();
  } finally {
    clearTimeout(timer);
    started.then((agent) => agent.close()).catch(() => {});
    rmSync(cwd, { recursive: true, force: true });
  }
}

/** Runs an ACP agent as a child process on this machine and talks to it over stdio. */
export class LocalAcpRunner implements AgentRunner {
  async start({ command, cwd, onEvent, onPermission, resumeSessionId, mcpServers }: StartOptions): Promise<AgentProcess> {
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
      const init = await Promise.race([
        agent.request("initialize", { protocolVersion: acp.PROTOCOL_VERSION, clientCapabilities: {} }),
        failedToSpawn,
        exited.then(() => Promise.reject(new Error("agent exited during startup"))),
      ]);

      if (command.authMethod) {
        if (!init.authMethods?.some((method) => method.id === command.authMethod)) {
          throw new Error(`agent does not offer auth method '${command.authMethod}'`);
        }
        await agent.request("authenticate", { methodId: command.authMethod });
      }

      const servers = mcpServers?.(init.agentCapabilities?.mcpCapabilities?.http === true) ?? [];
      let sessionId: string;
      if (resumeSessionId) {
        if (!init.agentCapabilities?.sessionCapabilities?.resume) throw new Error("agent cannot resume sessions");
        await agent.request("session/resume", { sessionId: resumeSessionId, cwd, mcpServers: servers });
        sessionId = resumeSessionId;
      } else {
        ({ sessionId } = await agent.request("session/new", { cwd, mcpServers: servers }));
      }

      return {
        sessionId,
        exited,
        close,
        async prompt(text, files = [], preface) {
          const prompt: acp.ContentBlock[] = [
            ...(preface ? [{ type: "text" as const, text: preface }] : []),
            { type: "text", text },
            ...files.map((path) => ({ type: "resource_link" as const, uri: pathToFileURL(path).href, name: basename(path) })),
          ];
          const response = await agent.request("session/prompt", { sessionId, prompt });
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
