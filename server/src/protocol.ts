// Wire types for protocol v1. Spec: protocol/v1.md. Keep in sync with mac/Sources/KervanKit/Protocol.swift.

export const PROTOCOL_VERSION = 1;

export const MAX_BUDGET_USD = 10_000;
const MAX_PROMPT_CHARS = 100_000;
const MAX_ATTACHMENTS = 20;

export interface PeerInfo {
  name: string;
  version: string;
}

/** `waiting`: the agent is blocked on a permission request the user hasn't answered yet. */
export type SessionStatus = "starting" | "idle" | "running" | "waiting" | "error" | "closed";

export interface PermissionChoice {
  optionId: string;
  name: string;
  /** ACP option kind: allow_once | allow_always | reject_once | reject_always */
  kind: string;
}

export interface SessionInfo {
  id: string;
  agent: string;
  title: string;
  status: SessionStatus;
  createdAt: string;
  archived: boolean;
  /** Skills and MCP servers chosen when the session was created. */
  skills: string[];
  mcpServers: string[];
  /** Set for team members: the team and the member's role name. */
  teamId?: string;
  role?: string;
  /** Set for helpers: the lead session that started them. */
  parentId?: string;
  /** The agent may start and message helpers (Kervan's orchestration tools). */
  orchestrate?: boolean;
  /** Leads: the most the lead and its helpers may spend together, in USD. */
  budgetUsd?: number;
  /** Helpers in a git repository: the branch of their own worktree. */
  branch?: string;
  /** Last reported by the agent; cost only from agents that report it (Claude). */
  usage?: SessionUsage;
  /** Choices the agent offers for this session (model, reasoning effort, mode), with the current value. */
  config?: ConfigOption[];
  /** The project whose folder the session works in. */
  projectId?: string;
  /** Set for sessions a scheduled task started. */
  scheduleId?: string;
  /** Set for a review: the session whose changes this one reviews (on a copy of its files). */
  reviewOf?: string;
  /** The lead judges the work's size and hands independent parts to helpers. */
  split?: boolean;
  /** A helper whose agent was stopped after sitting idle; the next message starts it again where it left off. */
  resting?: boolean;
  error?: string;
}

/** One of an agent's session settings, e.g. its model. Only select-style options; values are the agent's ids. */
export interface ConfigOption {
  id: string;
  name: string;
  /** ACP's hint: "model", "thought_level", "mode", … */
  category?: string;
  value: string;
  choices: { value: string; name: string; description?: string }[];
}

export interface SessionUsage {
  contextUsed: number;
  contextSize: number;
  /** Cumulative across agent restarts. */
  costUsd?: number;
}

/** An agent as clients list it. `terminal` agents run in a pseudo-terminal and answer in plain text. */
export interface AgentDetail {
  id: string;
  name: string;
  terminal?: boolean;
  /** Set when the agent runs on another node. */
  node?: string;
}

export type { HubAddress, NodeInfo } from "./nodes.ts";
import type { HubAddress, NodeInfo } from "./nodes.ts";

export interface TeamInfo {
  id: string;
  title: string;
  createdAt: string;
  /** Member sessions, in the order the roles were given. */
  sessionIds: string[];
}

export type { Role } from "./roles.ts";
import type { Role } from "./roles.ts";

export type { AgentSummary } from "./catalog.ts";
export type { OfferedAgent, OllamaStatus } from "./agentregistry.ts";
import type { OfferedAgent, OllamaStatus } from "./agentregistry.ts";
import type { AgentSummary } from "./catalog.ts";

export interface McpServerSummary {
  name: string;
  transport: "stdio" | "http";
  command?: string;
  args?: string[];
  url?: string;
  /** Names only; values never leave the server. */
  envKeys: string[];
  headerKeys: string[];
}

export interface SearchHit {
  sessionId: string;
  seq: number;
  role: "user" | "agent";
  /** Matched terms are wrapped in \u0001 … \u0002. */
  snippet: string;
}

/** A file edit the agent reported: the whole old and new text of the file (or of the changed part). */
export interface FileDiff {
  /** Relative to the session's folder when it is inside it. */
  path: string;
  /** Missing for a new file. */
  oldText?: string;
  newText: string;
  /** The texts were cut to keep the event small. */
  truncated?: boolean;
}

/** One step of the agent's plan (its to-do list). */
export interface PlanEntry {
  content: string;
  /** pending | in_progress | completed */
  status: string;
  /** high | medium | low */
  priority: string;
}

/** A slash command the agent offers, e.g. /review. */
export interface SlashCommand {
  name: string;
  description: string;
  /** What to type after the command, when it takes input. */
  hint?: string;
}

export interface ProjectInfo {
  id: string;
  name: string;
  /** Absolute path on the server. */
  path: string;
  /** Given to every agent in the project before its first message. */
  instructions: string;
  createdAt: string;
}

export type ScheduleWhen =
  /** Every day at `time` (HH:MM, in `timeZone`) on the given ISO weekdays (1 = Monday … 7 = Sunday). */
  | { kind: "daily"; time: string; weekdays: number[] }
  | { kind: "interval"; minutes: number };

export interface ScheduleInfo {
  id: string;
  title: string;
  agent: string;
  projectId?: string;
  prompt: string;
  when: ScheduleWhen;
  /** IANA name, e.g. Europe/Istanbul: the Mac's zone, so times mean what the user meant. */
  timeZone: string;
  enabled: boolean;
  createdAt: string;
  lastRunAt?: string;
  lastSessionId?: string;
  lastError?: string;
}

export interface ChangedFile {
  path: string;
  status: "added" | "modified" | "deleted";
  additions: number;
  deletions: number;
}

/** What changed in a session's folder since a checkpoint. */
export interface ChangeSet {
  files: ChangedFile[];
  patch: string;
  truncated: boolean;
  /** The user message whose checkpoint the changes are measured from; missing before the first message. */
  sinceSeq?: number;
  /** Files whose diff was left out for a browser because they look like secrets; still listed in `files`. */
  hiddenPaths?: string[];
  /** The folder is a git repository, so the changes can be committed there. */
  repository: boolean;
  branch?: string;
}

export interface UsageReport {
  /** One row per local day and agent that spent something. */
  days: { date: string; agent: string; costUsd: number }[];
  /** The sessions that spent the most in the period. */
  sessions: { sessionId: string; costUsd: number }[];
}

/** For "Report a problem": no prompts, no keys; log lines are redacted. */
/** Phone alerts as clients see them: the ntfy token and the webhook address are never sent back. */
export interface AlertSettings {
  enabled: boolean;
  events: { approval: boolean; finished: boolean; error: boolean };
  ntfy?: { server: string; topic: string; tokenSet: boolean };
  webhookSet: boolean;
  openUrl?: string;
  /** Alerts carry the session's name (which starts as the first line of its first message). */
  includeNames: boolean;
}

export type CardColumn = "todo" | "working" | "needs" | "review" | "done";

/** A task on a project's board. Once moved to Working it has a session, and its column follows that session. */
export interface CardInfo {
  id: string;
  projectId: string;
  title: string;
  prompt: string;
  agent: string;
  /** The session it starts splits large work into helpers. */
  split?: boolean;
  column: CardColumn;
  sessionId?: string;
  /** The prompt has been sent; from here the column follows the session. */
  prompted?: boolean;
  createdAt: string;
  updatedAt: string;
}

/** Whether the server can push and open pull requests: gh installed, and signed in to GitHub as `account`. */
export interface GitHubStatus {
  available: boolean;
  signedIn: boolean;
  /** A sign-in is waiting for the user to enter its code. */
  signingIn: boolean;
  account?: string;
}

/** A browser paired for the web client. Its key is never sent back, only who it is. */
export interface WebDevice {
  id: string;
  name: string;
  createdAt: string;
  lastSeenAt?: string;
}

export interface WebAccessStatus {
  enabled: boolean;
  devices: WebDevice[];
}

/** A session's work put up for review. `url` is the pull request, or GitHub's compare page when `created` is false. */
export interface PullRequestInfo {
  branch: string;
  base: string;
  url?: string;
  created: boolean;
}

export interface Diagnostics {
  version: string;
  node: string;
  os: string;
  uptimeSec: number;
  agents: { id: string; available: boolean; signedIn?: boolean; node: string }[];
  nodes: { name: string; connected: boolean; version?: string }[];
  /** Sessions by status. */
  sessions: Record<string, number>;
  logs: string[];
}

export interface ListeningPort {
  port: number;
  /** The program listening, when the server may see it. */
  process?: string;
}

// Agent-neutral events. Runners translate their agent's own updates (ACP, PTY…) into these.
export type SessionEventBody =
  /** `from` is the lead session when a lead agent, not the user, wrote it. */
  | { kind: "user_message"; text: string; attachments?: string[]; from?: string }
  | { kind: "agent_message_chunk"; text: string }
  | { kind: "agent_thought_chunk"; text: string }
  | { kind: "tool_call"; toolCallId: string; title: string; toolKind: string; status: string; diffs?: FileDiff[] }
  | { kind: "tool_call_update"; toolCallId: string; title?: string; status?: string; diffs?: FileDiff[] }
  /** The agent's whole plan as it stands; each one replaces the last. */
  | { kind: "plan"; entries: PlanEntry[] }
  /** The slash commands the agent offers now; each one replaces the last. */
  | { kind: "commands"; commands: SlashCommand[] }
  /** The session's files as they were just before the user message `messageSeq` (a commit in Kervan's own store). */
  | { kind: "checkpoint"; commit: string; messageSeq: number }
  | {
      kind: "permission_request";
      requestId: string;
      title: string;
      toolKind: string;
      detail?: string;
      options: PermissionChoice[];
    }
  | { kind: "permission_resolved"; requestId: string; outcome: "selected" | "cancelled"; optionId?: string }
  | { kind: "turn_end"; stopReason: string }
  /** Something Kervan itself did, e.g. recovering the session after a server restart. */
  | { kind: "notice"; text: string }
  | { kind: "error"; message: string };

export type SessionEvent = SessionEventBody & { seq: number; at: string };

export type ClientMessage =
  | { type: "hello"; protocol: number; client: PeerInfo }
  | { type: "ping"; id: string }
  /** In a git project the session gets a worktree of its own unless `shared` asks for the project folder itself. */
  | { type: "session.create"; id: string; agent: string; skills?: string[]; mcpServers?: string[]; orchestrate?: boolean; budgetUsd?: number; projectId?: string; shared?: boolean; split?: boolean }
  /** `since` "session": everything since the first message; "turn": since the last one. */
  | { type: "session.changes"; id: string; sessionId: string; since?: "session" | "turn" }
  /** Puts files (all when `paths` is missing) back as they were before the user message `seq`. */
  | { type: "session.revert"; id: string; sessionId: string; seq: number; paths?: string[] }
  | { type: "session.commit"; id: string; sessionId: string; message: string }
  /** Commits what is left on a branch of its own, pushes it and opens a pull request. */
  | { type: "session.pullRequest"; id: string; sessionId: string; title: string; body?: string }
  /** Starts `agent` reviewing the session's changes on a copy of its files; the review is a session of its own. */
  | { type: "session.review"; id: string; sessionId: string; agent: string }
  /** Web access is managed from the app only; paired browsers can't reach these. */
  | { type: "web.status"; id: string }
  | { type: "web.enable"; id: string; enabled: boolean }
  | { type: "web.pair"; id: string }
  | { type: "web.revoke"; id: string; deviceId: string }
  /** Phone alerts (ntfy, webhook), from the app only. */
  | { type: "alerts.get"; id: string }
  | { type: "alerts.save"; id: string; alerts: Record<string, unknown> }
  | { type: "alerts.test"; id: string }
  /** A project's task board. */
  | { type: "board.list"; id: string; projectId: string }
  | { type: "card.save"; id: string; card: Record<string, unknown> }
  /** Moving a card that hasn't started to "working" starts its session with the card's prompt. */
  | { type: "card.move"; id: string; cardId: string; column: string }
  | { type: "card.delete"; id: string; cardId: string }
  /** GitHub sign-in for the server's gh, from the app only. */
  | { type: "github.status"; id: string }
  | { type: "github.connect"; id: string }
  | { type: "github.disconnect"; id: string }
  /** Signs a builtin agent (claude, codex) in with the user's own account rather than an API key. */
  | { type: "agent.login"; id: string; agent: string }
  /** Claude's code from the page the user signed in on. */
  | { type: "agent.login.code"; id: string; agent: string; code: string }
  | { type: "agent.login.cancel"; id: string; agent: string }
  | { type: "agent.logout"; id: string; agent: string }
  /** The agents of the ACP registry and where each stands on this server, and the server's Ollama. */
  | { type: "agent.registry"; id: string }
  /** Installs (or finds) a registry agent for the service user and adds it; optionally runs it on an Ollama model. */
  | { type: "agent.install"; id: string; agentId: string; ollamaModel?: string }
  | { type: "project.list"; id: string }
  | { type: "project.save"; id: string; project: Record<string, unknown> }
  | { type: "project.delete"; id: string; projectId: string }
  | { type: "schedule.list"; id: string }
  | { type: "schedule.save"; id: string; schedule: Record<string, unknown> }
  | { type: "schedule.delete"; id: string; scheduleId: string }
  | { type: "schedule.run"; id: string; scheduleId: string }
  | { type: "usage.report"; id: string; days: number; timeZone: string }
  | { type: "terminal.open"; id: string; sessionId: string }
  | { type: "terminal.input"; id: string; terminalId: string; data: string }
  | { type: "terminal.close"; id: string; terminalId: string }
  | { type: "port.list"; id: string }
  | { type: "diagnostics"; id: string }
  | { type: "session.list"; id: string }
  | { type: "node.list"; id: string }
  | { type: "node.invite"; id: string; name: string }
  | { type: "node.remove"; id: string; name: string }
  | { type: "session.config"; id: string; sessionId: string; configId: string; value: string }
  | { type: "session.history"; id: string; sessionId: string }
  | { type: "session.prompt"; id: string; sessionId: string; text: string; attachments?: string[] }
  | { type: "session.cancel"; id: string; sessionId: string }
  | { type: "session.permission"; id: string; sessionId: string; requestId: string; optionId: string }
  | { type: "session.rename"; id: string; sessionId: string; title: string }
  /** `removeWorktree` (when archiving) also takes away a project session's worktree; its work stays on its branch. */
  | { type: "session.archive"; id: string; sessionId: string; archived: boolean; removeWorktree?: boolean }
  | { type: "session.search"; id: string; query: string }
  | { type: "mcp.list"; id: string }
  | { type: "mcp.save"; id: string; server: Record<string, unknown> }
  | { type: "mcp.delete"; id: string; name: string }
  | { type: "agent.list"; id: string }
  | { type: "agent.save"; id: string; agent: Record<string, unknown> }
  | { type: "agent.delete"; id: string; agentId: string }
  | { type: "role.list"; id: string }
  | { type: "role.save"; id: string; role: Record<string, unknown> }
  | { type: "role.delete"; id: string; roleId: string }
  | { type: "team.create"; id: string; title: string; roles: string[] }
  | { type: "team.list"; id: string };

export type ErrorCode =
  | "bad_message"
  | "unknown_type"
  | "hello_required"
  | "unsupported_protocol"
  | "unknown_agent"
  | "unknown_session"
  | "session_busy"
  | "session_unavailable"
  | "unknown_request"
  /** The agent's node isn't connected right now. */
  | "node_offline"
  /** A paired browser asked for something only the app may do. */
  | "forbidden"
  /** The request failed in a way the server didn't expect; its log has the details. */
  | "internal";

export type ServerMessage =
  | { type: "welcome"; protocol: number; server: PeerInfo; agents: string[]; agentDetails: AgentDetail[] }
  | { type: "pong"; id: string }
  | { type: "ok"; id: string }
  | { type: "error"; code: ErrorCode; message: string; id?: string }
  | { type: "session.created"; id: string; session: SessionInfo }
  | { type: "session.list.result"; id: string; sessions: SessionInfo[] }
  | { type: "session.history.result"; id: string; sessionId: string; events: SessionEvent[] }
  | { type: "session.updated"; session: SessionInfo }
  | { type: "session.event"; sessionId: string; event: SessionEvent }
  | { type: "session.search.result"; id: string; hits: SearchHit[] }
  | { type: "mcp.list.result"; id: string; servers: McpServerSummary[] }
  | { type: "agent.list.result"; id: string; agents: AgentSummary[]; nodes: string[] }
  | { type: "role.list.result"; id: string; roles: Role[] }
  | { type: "team.created"; id: string; team: TeamInfo }
  | { type: "team.list.result"; id: string; teams: TeamInfo[] }
  | { type: "team.updated"; team: TeamInfo }
  /** Broadcast after the agent catalog changes, in the same shape as `welcome`. */
  | { type: "agents.updated"; agents: string[]; agentDetails: AgentDetail[] }
  | { type: "node.list.result"; id: string; nodes: NodeInfo[]; hubAddresses: HubAddress[] }
  | { type: "node.invited"; id: string; name: string; code: string; expiresAt: string }
  | { type: "nodes.updated"; nodes: NodeInfo[]; hubAddresses: HubAddress[] }
  | { type: "session.changes.result"; id: string; sessionId: string; changes: ChangeSet }
  | { type: "project.list.result"; id: string; projects: ProjectInfo[] }
  /** Broadcast after a project was added, changed or removed. */
  | { type: "projects.updated"; projects: ProjectInfo[] }
  | { type: "schedule.list.result"; id: string; schedules: ScheduleInfo[] }
  /** Broadcast after a schedule ran or changed. */
  | { type: "schedules.updated"; schedules: ScheduleInfo[] }
  | { type: "usage.report.result"; id: string; report: UsageReport }
  /** `backlog` is what the terminal printed before this client opened it. */
  | { type: "terminal.opened"; id: string; terminalId: string; sessionId: string; backlog: string }
  | { type: "terminal.output"; terminalId: string; data: string }
  | { type: "terminal.exited"; terminalId: string }
  | { type: "port.list.result"; id: string; ports: ListeningPort[] }
  | { type: "diagnostics.result"; id: string; report: Diagnostics }
  | { type: "session.pullRequest.result"; id: string; sessionId: string; pullRequest: PullRequestInfo }
  | { type: "web.status.result"; id: string; web: WebAccessStatus }
  | { type: "web.paired"; id: string; code: string; expiresAt: string }
  | { type: "alerts.result"; id: string; alerts: AlertSettings }
  | { type: "board.result"; id: string; projectId: string; cards: CardInfo[] }
  /** Sent to everyone when any card of the project changes, by hand or by following its session. */
  | { type: "board.updated"; projectId: string; cards: CardInfo[] }
  | { type: "github.status.result"; id: string; github: GitHubStatus }
  /** The code to enter at `url`; `github.updated` follows when the sign-in ends. */
  | { type: "github.code"; id: string; code: string; url: string }
  | { type: "github.updated"; github: GitHubStatus; error?: string }
  /** The page to sign in on; for Codex the code to enter there, for Claude `needsCode` asks for the code it shows. */
  | { type: "agent.login.started"; id: string; agent: string; url: string; code?: string; needsCode: boolean }
  /** A sign-in ended; the agent list has the new `signedIn`. */
  | { type: "agent.login.finished"; agent: string; signedIn: boolean; error?: string }
  | { type: "agent.registry.result"; id: string; agents: OfferedAgent[]; ollama: OllamaStatus };

export type ParseResult =
  | { ok: true; message: ClientMessage }
  | { ok: false; code: ErrorCode; message: string; id?: string };

/** Raised by request handlers; ws.ts turns it into an `error` reply carrying the request id. */
export class KervanError extends Error {
  readonly code: ErrorCode;

  constructor(code: ErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPeerInfo(value: unknown): value is PeerInfo {
  return isRecord(value) && typeof value.name === "string" && typeof value.version === "string";
}

// Request types whose fields are all required strings.
const STRING_FIELDS: Record<string, readonly string[]> = {
  ping: ["id"],
  "session.create": ["id", "agent"],
  "node.list": ["id"],
  "node.invite": ["id", "name"],
  "node.remove": ["id", "name"],
  "session.config": ["id", "sessionId", "configId", "value"],
  "session.list": ["id"],
  "session.history": ["id", "sessionId"],
  "session.prompt": ["id", "sessionId", "text"],
  "session.cancel": ["id", "sessionId"],
  "session.permission": ["id", "sessionId", "requestId", "optionId"],
  "session.rename": ["id", "sessionId", "title"],
  "session.archive": ["id", "sessionId"],
  "session.search": ["id", "query"],
  "mcp.list": ["id"],
  "mcp.save": ["id"],
  "mcp.delete": ["id", "name"],
  "agent.list": ["id"],
  "agent.save": ["id"],
  "agent.delete": ["id", "agentId"],
  "role.list": ["id"],
  "role.save": ["id"],
  "role.delete": ["id", "roleId"],
  "team.create": ["id", "title"],
  "team.list": ["id"],
  "session.changes": ["id", "sessionId"],
  "session.revert": ["id", "sessionId"],
  "session.commit": ["id", "sessionId", "message"],
  "session.pullRequest": ["id", "sessionId", "title"],
  "session.review": ["id", "sessionId", "agent"],
  "web.status": ["id"],
  "web.enable": ["id"],
  "web.pair": ["id"],
  "web.revoke": ["id", "deviceId"],
  "alerts.get": ["id"],
  "alerts.save": ["id"],
  "alerts.test": ["id"],
  "board.list": ["id", "projectId"],
  "card.save": ["id"],
  "card.move": ["id", "cardId", "column"],
  "card.delete": ["id", "cardId"],
  "github.status": ["id"],
  "github.connect": ["id"],
  "github.disconnect": ["id"],
  "agent.login": ["id", "agent"],
  "agent.login.code": ["id", "agent", "code"],
  "agent.login.cancel": ["id", "agent"],
  "agent.logout": ["id", "agent"],
  "agent.registry": ["id"],
  "agent.install": ["id", "agentId"],
  "project.list": ["id"],
  "project.save": ["id"],
  "project.delete": ["id", "projectId"],
  "schedule.list": ["id"],
  "schedule.save": ["id"],
  "schedule.delete": ["id", "scheduleId"],
  "schedule.run": ["id", "scheduleId"],
  "usage.report": ["id", "timeZone"],
  "terminal.open": ["id", "sessionId"],
  "terminal.input": ["id", "terminalId", "data"],
  "terminal.close": ["id", "terminalId"],
  "port.list": ["id"],
  diagnostics: ["id"],
};

const MAX_TEAM = 8;

const MAX_SELECTED = 32;

export function parseClientMessage(raw: string): ParseResult {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return { ok: false, code: "bad_message", message: "frame is not valid JSON" };
  }
  if (!isRecord(data) || typeof data.type !== "string") {
    return { ok: false, code: "bad_message", message: "expected a JSON object with a string 'type'" };
  }

  const fail = (code: ErrorCode, message: string): ParseResult =>
    typeof data.id === "string" ? { ok: false, code, message, id: data.id } : { ok: false, code, message };

  if (data.type === "hello") {
    if (typeof data.protocol !== "number" || !isPeerInfo(data.client)) {
      return fail("bad_message", "hello needs 'protocol' and 'client: {name, version}'");
    }
    return { ok: true, message: { type: "hello", protocol: data.protocol, client: data.client } };
  }

  const fields = STRING_FIELDS[data.type];
  if (!fields) {
    return fail("unknown_type", `unknown message type '${data.type}'`);
  }
  const message: Record<string, string> = { type: data.type };
  for (const field of fields) {
    const value = data[field];
    if (typeof value !== "string") {
      return fail("bad_message", `${data.type} needs a string '${field}'`);
    }
    message[field] = value;
  }
  if (data.type === "session.prompt" && (message.text.trim() === "" || message.text.length > MAX_PROMPT_CHARS)) {
    return fail("bad_message", `prompt text must be 1–${MAX_PROMPT_CHARS} characters`);
  }
  if (data.type === "session.create") {
    for (const field of ["skills", "mcpServers"] as const) {
      const list = data[field];
      if (list === undefined) continue;
      if (!Array.isArray(list) || list.length > MAX_SELECTED || !list.every((x) => typeof x === "string")) {
        return fail("bad_message", `${field} must be up to ${MAX_SELECTED} names`);
      }
      (message as Record<string, unknown>)[field] = list;
    }
    if (data.orchestrate !== undefined) {
      if (typeof data.orchestrate !== "boolean") return fail("bad_message", "orchestrate must be true or false");
      (message as Record<string, unknown>).orchestrate = data.orchestrate;
    }
    if (data.split !== undefined) {
      if (typeof data.split !== "boolean") return fail("bad_message", "split must be true or false");
      (message as Record<string, unknown>).split = data.split;
    }
    if (data.shared !== undefined) {
      if (typeof data.shared !== "boolean") return fail("bad_message", "shared must be true or false");
      (message as Record<string, unknown>).shared = data.shared;
    }
    if (data.budgetUsd !== undefined) {
      if (typeof data.budgetUsd !== "number" || !(data.budgetUsd > 0 && data.budgetUsd <= MAX_BUDGET_USD)) {
        return fail("bad_message", `budgetUsd must be a number between 0 and ${MAX_BUDGET_USD}`);
      }
      (message as Record<string, unknown>).budgetUsd = data.budgetUsd;
    }
    if (data.projectId !== undefined) {
      if (typeof data.projectId !== "string") return fail("bad_message", "projectId must be a string");
      (message as Record<string, unknown>).projectId = data.projectId;
    }
  }
  if (data.type === "session.changes" && data.since !== undefined) {
    if (data.since !== "session" && data.since !== "turn") return fail("bad_message", "since must be 'session' or 'turn'");
    (message as Record<string, unknown>).since = data.since;
  }
  if (data.type === "session.revert") {
    if (!Number.isInteger(data.seq)) return fail("bad_message", "session.revert needs a whole number 'seq'");
    (message as Record<string, unknown>).seq = data.seq;
    if (data.paths !== undefined) {
      const list = data.paths;
      if (!Array.isArray(list) || list.length === 0 || list.length > 500 || !list.every((p) => typeof p === "string")) {
        return fail("bad_message", "paths must be 1–500 paths");
      }
      (message as Record<string, unknown>).paths = list;
    }
  }
  if (data.type === "session.commit" && (message.message.trim() === "" || message.message.length > 5000)) {
    return fail("bad_message", "commit message must be 1–5000 characters");
  }
  if (data.type === "web.enable") {
    if (typeof data.enabled !== "boolean") return fail("bad_message", "web.enable needs a boolean 'enabled'");
    (message as Record<string, unknown>).enabled = data.enabled;
  }
  if (data.type === "session.pullRequest") {
    if (message.title.trim() === "" || message.title.length > 250) return fail("bad_message", "title must be 1–250 characters");
    if (data.body !== undefined && (typeof data.body !== "string" || data.body.length > 20_000)) {
      return fail("bad_message", "body must be text up to 20000 characters");
    }
    (message as Record<string, unknown>).body = data.body ?? "";
  }
  for (const [type, field] of [["project.save", "project"], ["schedule.save", "schedule"], ["card.save", "card"], ["alerts.save", "alerts"]] as const) {
    if (data.type !== type) continue;
    if (!isRecord(data[field])) return fail("bad_message", `${type} needs a '${field}' object`);
    (message as Record<string, unknown>)[field] = data[field];
  }
  if (data.type === "usage.report") {
    const days = data.days ?? 30;
    if (typeof days !== "number" || !Number.isInteger(days) || days < 1 || days > 366) return fail("bad_message", "days must be 1–366");
    (message as Record<string, unknown>).days = days;
  }
  if (data.type === "terminal.input" && message.data.length > 64_000) return fail("bad_message", "terminal input is too long");
  if (data.type === "role.save") {
    if (!isRecord(data.role)) return fail("bad_message", "role.save needs a 'role' object");
    (message as Record<string, unknown>).role = data.role;
  }
  if (data.type === "team.create") {
    const roles = data.roles;
    if (!Array.isArray(roles) || roles.length === 0 || roles.length > MAX_TEAM || !roles.every((r) => typeof r === "string")) {
      return fail("bad_message", `a team needs 1–${MAX_TEAM} roles`);
    }
    if (message.title.trim() === "" || message.title.length > 120) return fail("bad_message", "team title must be 1–120 characters");
    (message as Record<string, unknown>).roles = roles;
  }
  if (data.type === "agent.save") {
    if (!isRecord(data.agent)) return fail("bad_message", "agent.save needs an 'agent' object");
    (message as Record<string, unknown>).agent = data.agent;
  }
  if (data.type === "mcp.save") {
    if (!isRecord(data.server)) return fail("bad_message", "mcp.save needs a 'server' object");
    (message as Record<string, unknown>).server = data.server;
  }
  if (data.type === "session.archive") {
    if (typeof data.archived !== "boolean") return fail("bad_message", "session.archive needs a boolean 'archived'");
    (message as Record<string, unknown>).archived = data.archived;
    if (data.removeWorktree !== undefined) {
      if (typeof data.removeWorktree !== "boolean") return fail("bad_message", "removeWorktree must be true or false");
      (message as Record<string, unknown>).removeWorktree = data.removeWorktree;
    }
  }
  if (data.type === "session.rename" && (message.title.trim() === "" || message.title.length > 120)) {
    return fail("bad_message", "title must be 1–120 characters");
  }
  if (data.type === "session.prompt" && data.attachments !== undefined) {
    const list = data.attachments;
    if (!Array.isArray(list) || list.length > MAX_ATTACHMENTS || !list.every((a) => typeof a === "string")) {
      return fail("bad_message", `attachments must be up to ${MAX_ATTACHMENTS} paths`);
    }
    (message as Record<string, unknown>).attachments = list;
  }
  return { ok: true, message: message as unknown as ClientMessage };
}
