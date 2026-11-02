import { spawn } from "node:child_process";
import { startPty } from "./pty.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, isAbsolute, join, relative, sep } from "node:path";
import { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentCommand } from "./agents.ts";
import { agentEnv } from "./agentenv.ts";
import { log } from "./log.ts";
import type { ConfigOption, FileDiff, PermissionChoice, SessionEventBody } from "./protocol.ts";

/** One running agent conversation. */
export interface AgentProcess {
  /**
   * Resolves with the stop reason once the agent finishes the turn. `files` are absolute paths;
   * `preface` is context for the agent that the user didn't type (e.g. the session's skills).
   */
  prompt(text: string, files?: string[], preface?: string): Promise<string>;
  cancel(): Promise<void>;
  /** Changes one of the agent's session settings; resolves with all of them. Missing when the agent has none (PTY). */
  setConfig?(configId: string, value: string): Promise<ConfigOption[]>;
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
  /** Context and cost as the agent reports them; `costUsd` counts from this agent process's start. */
  onUsage?: (usage: { used: number; size: number; costUsd?: number }) => void;
  /** The agent's session settings (model, effort, mode) whenever they are first known or change. */
  onConfig?: (options: ConfigOption[]) => void;
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
  async start(options: StartOptions): Promise<AgentProcess> {
    if (options.command.protocol === "pty") return startPty(options);
    const { command, cwd, onEvent, onPermission, resumeSessionId, mcpServers, onUsage, onConfig } = options;
    const child = spawn(command.command, command.args, {
      cwd,
      env: agentEnv(command),
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

    const settings = new AgentSettings((options) => onConfig?.(options));
    const app = acp
      .client({ name: "kervan" })
      .onNotification("session/update", ({ params }) => {
        const update = params.update;
        if (update.sessionUpdate === "config_option_update") {
          settings.native(update.configOptions);
          return;
        }
        if (update.sessionUpdate === "current_mode_update") {
          settings.modeChanged(update.currentModeId);
          return;
        }
        if (update.sessionUpdate === "usage_update") {
          const cost = update.cost?.currency === "USD" ? update.cost.amount : undefined;
          onUsage?.({ used: update.used, size: update.size, ...(cost !== undefined ? { costUsd: cost } : {}) });
          return;
        }
        const event = toEvent(update, cwd);
        if (event) onEvent(event);
      })
      .onRequest("session/request_permission", async ({ params }) => {
        const optionId = await onPermission({
          title: params.toolCall.title ?? "Tool call",
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
        const resumed = await agent.request("session/resume", { sessionId: resumeSessionId, cwd, mcpServers: servers });
        sessionId = resumeSessionId;
        settings.started(resumed);
      } else {
        const created = await agent.request("session/new", { cwd, mcpServers: servers });
        sessionId = created.sessionId;
        settings.started(created);
      }

      return {
        sessionId,
        exited,
        close,
        async prompt(text, files = [], preface) {
          // Agents that see images get pictures as pictures; every file is linked as well, so it can be opened by path.
          const seesImages = init.agentCapabilities?.promptCapabilities?.image === true;
          const images = seesImages ? await Promise.all(files.map(imageBlock)) : [];
          const prompt: acp.ContentBlock[] = [
            ...(preface ? [{ type: "text" as const, text: preface }] : []),
            { type: "text", text },
            ...images.filter((block) => block !== null),
            ...files.map((path) => ({ type: "resource_link" as const, uri: pathToFileURL(path).href, name: basename(path) })),
          ];
          const response = await agent.request("session/prompt", { sessionId, prompt });
          return response.stopReason;
        },
        async cancel() {
          await agent.notify("session/cancel", { sessionId });
        },
        async setConfig(configId, value) {
          if (configId === LEGACY_MODEL) {
            await agent.request("session/set_model", { sessionId, modelId: value });
            return settings.legacyChanged(configId, value);
          }
          if (configId === LEGACY_MODE) {
            await agent.request("session/set_mode", { sessionId, modeId: value });
            return settings.legacyChanged(configId, value);
          }
          const { configOptions } = await agent.request("session/set_config_option", { sessionId, configId, value });
          return settings.native(configOptions);
        },
      };
    } catch (error) {
      close();
      throw error;
    }
  }
}

// Settings offered the older ACP way (Gemini CLI): `models` / `modes` on session/new and session/resume,
// changed with session/set_model / session/set_mode. Shown like config options under these ids.
const LEGACY_MODEL = "acp:model";
const LEGACY_MODE = "acp:mode";

interface LegacyState {
  models?: { currentModelId: string; availableModels: { modelId: string; name: string; description?: string | null }[] } | null;
  modes?: acp.SessionModeState | null;
  configOptions?: acp.SessionConfigOption[] | null;
}

/**
 * An agent's session settings, whichever way it offers them: ACP config options, or the older
 * models/modes fields. The older ones fill in only what config options don't already cover.
 */
class AgentSettings {
  private nativeOptions: ConfigOption[] = [];
  private legacy: ConfigOption[] = [];
  private readonly publish: (options: ConfigOption[]) => void;

  constructor(publish: (options: ConfigOption[]) => void) {
    this.publish = publish;
  }

  started(response: LegacyState): void {
    this.nativeOptions = toConfig(response.configOptions ?? []);
    const has = (category: string) => this.nativeOptions.some((o) => o.category === category);
    const { models, modes } = response;
    this.legacy = [
      ...(models && models.availableModels.length > 0 && !has("model")
        ? [{
            id: LEGACY_MODEL,
            name: "Model",
            category: "model",
            value: models.currentModelId,
            choices: models.availableModels.map((m) => ({ value: m.modelId, name: m.name, ...(m.description ? { description: m.description } : {}) })),
          }]
        : []),
      ...(modes && modes.availableModes.length > 0 && !has("mode")
        ? [{
            id: LEGACY_MODE,
            name: "Mod",
            category: "mode",
            value: modes.currentModeId,
            choices: modes.availableModes.map((m) => ({ value: m.id, name: m.name, ...(m.description ? { description: m.description } : {}) })),
          }]
        : []),
    ];
    if (this.all.length > 0) this.publish(this.all);
  }

  native(options: acp.SessionConfigOption[]): ConfigOption[] {
    this.nativeOptions = toConfig(options);
    this.publish(this.all);
    return this.all;
  }

  legacyChanged(id: string, value: string): ConfigOption[] {
    this.legacy = this.legacy.map((o) => (o.id === id ? { ...o, value } : o));
    this.publish(this.all);
    return this.all;
  }

  modeChanged(modeId: string): void {
    if (this.legacy.some((o) => o.id === LEGACY_MODE)) this.legacyChanged(LEGACY_MODE, modeId);
  }

  private get all(): ConfigOption[] {
    return [...this.nativeOptions, ...this.legacy];
  }
}

/** The select-style options in Kervan's flat form; groups of choices are flattened. */
function toConfig(options: acp.SessionConfigOption[]): ConfigOption[] {
  return options.flatMap((option): ConfigOption[] => {
    if (option.type !== "select") return [];
    const choices = option.options.flatMap((entry) => ("group" in entry ? entry.options : [entry]));
    return [
      {
        id: option.id,
        name: option.name,
        ...(option.category ? { category: option.category } : {}),
        value: option.currentValue,
        choices: choices.map((c) => ({ value: c.value, name: c.name, ...(c.description ? { description: c.description } : {}) })),
      },
    ];
  });
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

const IMAGE_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};
/** Larger pictures are only linked; agents' own limits are around this size. */
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

async function imageBlock(path: string): Promise<acp.ContentBlock | null> {
  const mimeType = IMAGE_TYPES[extname(path).toLowerCase()];
  if (!mimeType) return null;
  try {
    if ((await stat(path)).size > MAX_IMAGE_BYTES) return null;
    return { type: "image", mimeType, data: (await readFile(path)).toString("base64"), uri: pathToFileURL(path).href };
  } catch {
    return null;
  }
}

/** Each side of a reported edit is cut to this; the Changes panel has the whole file from git. */
export const MAX_DIFF_CHARS = 40_000;

/** The edits in a tool call's content, with paths relative to the session folder. */
export function toDiffs(content: acp.ToolCallContent[] | null | undefined, cwd: string): FileDiff[] | undefined {
  const diffs = (content ?? []).flatMap((item): FileDiff[] => {
    if (item.type !== "diff") return [];
    const inside = isAbsolute(item.path) ? relative(cwd, item.path) : item.path;
    const path = inside.startsWith("..") || isAbsolute(inside) ? item.path : inside.split(sep).join("/");
    const oldText = item.oldText ?? undefined;
    const truncated = item.newText.length > MAX_DIFF_CHARS || (oldText?.length ?? 0) > MAX_DIFF_CHARS;
    return [{
      path,
      ...(oldText !== undefined ? { oldText: oldText.slice(0, MAX_DIFF_CHARS) } : {}),
      newText: item.newText.slice(0, MAX_DIFF_CHARS),
      ...(truncated ? { truncated: true } : {}),
    }];
  });
  return diffs.length > 0 ? diffs : undefined;
}

function toEvent(update: acp.SessionUpdate, cwd: string): SessionEventBody | null {
  switch (update.sessionUpdate) {
    case "agent_message_chunk":
    case "agent_thought_chunk":
      return update.content.type === "text" ? { kind: update.sessionUpdate, text: update.content.text } : null;
    case "tool_call": {
      const diffs = toDiffs(update.content, cwd);
      return {
        kind: "tool_call",
        toolCallId: update.toolCallId,
        title: update.title,
        toolKind: update.kind ?? "other",
        status: update.status ?? "pending",
        ...(diffs ? { diffs } : {}),
      };
    }
    case "tool_call_update": {
      const diffs = toDiffs(update.content, cwd);
      return {
        kind: "tool_call_update",
        toolCallId: update.toolCallId,
        ...(update.title ? { title: update.title } : {}),
        ...(update.status ? { status: update.status } : {}),
        ...(diffs ? { diffs } : {}),
      };
    }
    case "plan":
      return {
        kind: "plan",
        entries: update.entries.map(({ content, status, priority }) => ({ content, status, priority })),
      };
    case "available_commands_update":
      return {
        kind: "commands",
        commands: update.availableCommands.map((c) => ({
          name: c.name,
          description: c.description,
          ...(c.input?.hint ? { hint: c.input.hint } : {}),
        })),
      };
    default:
      return null;
  }
}
