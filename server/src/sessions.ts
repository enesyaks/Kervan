import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { cp, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AgentRegistry } from "./agents.ts";
import { isSafeRelativePath, placeFile } from "./files.ts";
import { log } from "./log.ts";
import {
  KervanError,
  type AgentDetail,
  type ChangeSet,
  type ConfigOption,
  type ProjectInfo,
  type PullRequestInfo,
  type ServerMessage,
  type TeamInfo,
  type SessionEvent,
  type SessionEventBody,
  type SessionInfo,
  type UsageReport,
} from "./protocol.ts";
import { commitAll, repositoryBranch, type Checkpoints } from "./checkpoints.ts";
import { openPullRequest } from "./pullrequest.ts";
import type { ProjectRegistry } from "./projects.ts";
import type { Board } from "./board.ts";
import type { ProjectMaps } from "./projectmap.ts";
import type { Alerts } from "./alerts.ts";
import { localParts, type Scheduler } from "./schedules.ts";
import { TerminalHub } from "./terminals.ts";
import type { AgentProcess, AgentRunner, PermissionDecision, PermissionRequest } from "./runner.ts";
import type { AgentCatalog } from "./catalog.ts";
import type { McpRegistry } from "./mcp.ts";
import type { SkillLibrary } from "./skills.ts";
import type { EventStore, IndexedMessage, SearchHit, StoredTeam } from "./store.ts";
import type { RoleRegistry } from "./roles.ts";
import type * as acp from "@agentclientprotocol/sdk";
import { isOrchestraCall } from "./orchestra.ts";
import { majorChange } from "./autoapprove.ts";
import { LOCAL_NODE, nodeOf, type NodeHub } from "./nodes.ts";
import {
  addWorktree,
  branchDiff,
  branchName,
  hasCommits,
  mergeBranch,
  removeWorktree as removeWorktreeAt,
  restoreWorktree,
  type MergeResult,
} from "./worktree.ts";

const fail = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/** Where a skill lands in a workspace when the agent has no skills folder of its own. */
const FALLBACK_SKILLS_DIR = ".kervan/skills";

const DEFAULT_TITLE = "New session";
/** The default title before the app went English; such sessions still take their first message as title. */
const OLD_DEFAULT_TITLE = "Yeni oturum";
const TITLE_CHARS = 60;
/** Per lead, unless configured otherwise; a runaway lead can't fill the server with agents. */
export const MAX_HELPERS = 6;
/** A helper's turn is stopped after this long, unless configured otherwise. */
export const HELPER_TURN_MINUTES = 30;
/** A helper idle this long has its agent stopped (it starts again with the next message), unless configured otherwise. */
export const HELPER_IDLE_MINUTES = 10;

export interface Limits {
  maxHelpers: number;
  /** 0 turns the limit off. */
  helperTurnMinutes: number;
  /** 0 keeps idle helpers' agents running. */
  helperIdleMinutes: number;
}
const REPLY_CHARS = 20_000;

/** What a lead agent learns about one of its helpers. */
export interface HelperSummary {
  helperId: string;
  name: string;
  agent: string;
  status: SessionInfo["status"];
  /** False while the helper is still working (or waiting for the user's approval). */
  done: boolean;
  /** Set when it works on its own branch (a separate git worktree). */
  branch?: string;
  costUsd?: number;
  /** Something the lead should know, e.g. why the helper isn't isolated. */
  note?: string;
  /** The helper's last answer. */
  reply?: string;
  error?: string;
}

/** Hands lead agents the MCP server with Kervan's orchestration tools. */
export interface Orchestrator {
  mcpServer(sessionId: string): acp.McpServer;
}

interface CreateOptions {
  title?: string;
  teamId?: string;
  role?: string;
  instructions?: string;
  parentId?: string;
  orchestrate?: boolean;
  budgetUsd?: number;
  /** Start in a new worktree of this repository, on a branch of its own. */
  worktreeFrom?: string;
  /** Work in this project's folder, with its instructions. */
  projectId?: string;
  /** In a git project, work in the project folder itself instead of a worktree of its own. */
  shared?: boolean;
  /** Started by this scheduled task. */
  scheduleId?: string;
  /** A review of this session's changes. */
  reviewOf?: string;
  /** Judge the work's size and hand independent parts to helpers (implies `orchestrate`). */
  split?: boolean;
}

interface PendingPermission {
  request: PermissionRequest;
  optionIds: string[];
  resolve: (decision: PermissionDecision) => void;
}

interface Session {
  info: SessionInfo;
  events: SessionEvent[];
  cwd: string;
  process?: AgentProcess;
  /** The agent's own id for this conversation; lets us resume it after a restart. */
  agentSessionId?: string;
  /** Unanswered permission requests by requestId. They wait for as long as the user is away. */
  pending: Map<string, PendingPermission>;
  /** The agent message currently streaming, kept whole for the search index. */
  streaming?: IndexedMessage;
  /** Role instructions given to the agent before the first message. */
  instructions?: string;
  /** Settles once the agent has started (or failed to). */
  ready?: Promise<void>;
  /** Cost already spent before the current agent process started; agents report cost per process. */
  costBase: number;
  /** Stops a helper's turn that runs too long. */
  turnTimer?: NodeJS.Timeout;
  /** Leads: the budget ran out and everything was stopped once already. */
  budgetSpent?: boolean;
  /** Told to the agent with the next message, e.g. that the user put files back. */
  note?: string;
}

type Listener = (message: ServerMessage) => void;

/**
 * Owns agent sessions independently of any client connection: a session keeps running
 * when the Mac goes to sleep, and every connected client sees every session's events.
 * Every event and status change is written to the store first, so a server restart
 * keeps the history; the agent itself is resumed the next time the user writes.
 */
export class SessionManager {
  private readonly sessions = new Map<string, Session>();
  private readonly listeners = new Set<Listener>();
  private readonly runner: AgentRunner;
  private readonly agents: AgentRegistry;
  private readonly workspacesDir: string;
  private readonly store: EventStore;
  /** Set by closeAll: agents may still emit a few events while dying, and the store is closing. */
  private shuttingDown = false;

  readonly skills?: SkillLibrary;
  readonly mcp?: McpRegistry;
  readonly catalog?: AgentCatalog;
  readonly roles?: RoleRegistry;
  private readonly teams = new Map<string, StoredTeam>();
  private orchestra?: Orchestrator;
  readonly limits: Limits;
  readonly nodes?: NodeHub;
  readonly projects?: ProjectRegistry;
  private readonly checkpoints?: Checkpoints;
  /** Set once the scheduler exists (it needs this manager to start its sessions). */
  scheduler?: Scheduler;
  board?: Board;
  maps?: ProjectMaps;
  /** Helpers waiting to rest, by session id. */
  private readonly idleTimers = new Map<string, NodeJS.Timeout>();
  alerts?: Alerts;
  /** The user's shells in session folders; their output goes to every client. */
  readonly terminals = new TerminalHub((message) => this.broadcast(message));

  constructor(
    runner: AgentRunner,
    agents: AgentRegistry,
    workspacesDir: string,
    store: EventStore,
    extras: {
      skills?: SkillLibrary;
      mcp?: McpRegistry;
      catalog?: AgentCatalog;
      roles?: RoleRegistry;
      limits?: Partial<Limits>;
      nodes?: NodeHub;
      projects?: ProjectRegistry;
      checkpoints?: Checkpoints;
    } = {},
  ) {
    this.projects = extras.projects;
    this.checkpoints = extras.checkpoints;
    this.nodes = extras.nodes;
    this.limits = { maxHelpers: MAX_HELPERS, helperTurnMinutes: HELPER_TURN_MINUTES, helperIdleMinutes: HELPER_IDLE_MINUTES, ...extras.limits };
    this.roles = extras.roles;
    this.skills = extras.skills;
    this.mcp = extras.mcp;
    this.catalog = extras.catalog;
    this.runner = runner;
    this.agents = agents;
    this.workspacesDir = workspacesDir;
    this.store = store;
    for (const stored of store.loadSessions()) {
      const session: Session = {
        info: stored.info,
        events: store.loadEvents(stored.info.id),
        cwd: this.cwdFor(workspacesDir, stored.info),
        agentSessionId: stored.agentSessionId,
        instructions: stored.instructions,
        pending: new Map(),
        costBase: stored.info.usage?.costUsd ?? 0,
      };
      this.sessions.set(session.info.id, session);
      this.recover(session);
    }
    for (const team of store.loadTeams()) this.teams.set(team.id, team);
  }

  /** Lets sessions created with `orchestrate` start helpers. Set once, after construction (the hub needs this manager). */
  useOrchestra(orchestra: Orchestrator): void {
    this.orchestra = orchestra;
  }

  get agentKinds(): string[] {
    return [...this.agents.keys()];
  }

  get agentDetails(): AgentDetail[] {
    return [...this.agents].map(([id, agent]) => ({
      id,
      name: agent.name,
      ...(agent.protocol === "pty" ? { terminal: true } : {}),
      ...(nodeOf(agent) !== LOCAL_NODE ? { node: nodeOf(agent), online: this.nodes?.isConnected(nodeOf(agent)) ?? false } : {}),
    }));
  }

  /** Tell every client which nodes exist and which are connected. */
  nodesChanged(): void {
    // The agent list says which agents are reachable, and it's all a browser hears about nodes.
    this.agentsChanged();
    if (this.nodes) this.broadcast({ type: "nodes.updated", nodes: this.nodes.list(), hubAddresses: this.nodes.addresses() });
  }

  /**
   * Where a session's files are: a folder on this server, or a workspace key on a node.
   * Remote workspaces are named by a key relative to the node's own workspaces folder.
   */
  location(sessionId: string): { path: string } | { node: string; key: string } {
    const session = this.require(sessionId);
    const node = this.nodeFor(session.info);
    return node === LOCAL_NODE ? { path: session.cwd } : { node, key: session.cwd };
  }

  /** The node an agent runs on when it isn't this server; for work that can only happen here. */
  remoteNode(agent: string): string | undefined {
    const node = nodeOf(this.agents.get(agent));
    return node === LOCAL_NODE ? undefined : node;
  }

  /** New work is refused while its node is away, so it doesn't leave a session that can never start. */
  private requireOnline(node: string): void {
    if (node !== LOCAL_NODE && !this.nodes?.isConnected(node)) throw new KervanError("node_offline", `node '${node}' is asleep or offline`);
  }

  private nodeFor(info: SessionInfo): string {
    return nodeOf(this.agents.get(info.agent));
  }

  /** Tell every client the agent list changed (agents added or removed from the app). */
  agentsChanged(): void {
    this.broadcast({ type: "agents.updated", agents: this.agentKinds, agentDetails: this.agentDetails });
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  list(): SessionInfo[] {
    return [...this.sessions.values()].map((s) => s.info);
  }

  history(sessionId: string): SessionEvent[] {
    return this.require(sessionId).events;
  }

  /** Absolute path of the session's working folder. */
  workspace(sessionId: string): string {
    return this.require(sessionId).cwd;
  }

  async create(
    agent: string,
    skills: string[] = [],
    mcpServers: string[] = [],
    options: CreateOptions = {},
  ): Promise<SessionInfo> {
    const missingSkill = skills.find((name) => !this.skills?.has(name));
    if (missingSkill) throw new KervanError("bad_message", `no skill named '${missingSkill}'`);
    const missingMcp = mcpServers.find((name) => !this.mcp?.has(name));
    if (missingMcp) throw new KervanError("bad_message", `no MCP server named '${missingMcp}'`);
    if (!this.agents.has(agent)) throw new KervanError("unknown_agent", `no agent named '${agent}'`);
    if (options.orchestrate && !this.orchestra) throw new KervanError("bad_message", "this server can't start helpers");
    const node = nodeOf(this.agents.get(agent));
    if (node !== LOCAL_NODE) {
      if (options.orchestrate || options.split) throw new KervanError("bad_message", `a lead must run on this server; '${agent}' runs on node '${node}'`);
      if (skills.length > 0) throw new KervanError("bad_message", `skills aren't available on node '${node}' yet`);
      if (!this.nodes) throw new KervanError("node_offline", `this server doesn't accept nodes, so '${agent}' can't run`);
      this.requireOnline(node);
    }
    if (options.orchestrate && this.agents.get(agent)?.protocol === "pty") {
      throw new KervanError("bad_message", "terminal agents can't use Kervan's tools, so they can't start helpers");
    }
    if (options.projectId) {
      if (!this.projects?.get(options.projectId)) throw new KervanError("bad_message", `no project '${options.projectId}'`);
      if (node !== LOCAL_NODE) throw new KervanError("bad_message", `projects live on this server; '${agent}' runs on node '${node}'`);
    }
    // Sessions in a git project each get a worktree and branch of their own, so two of them never edit the same
    // files. Team members share on purpose, helpers already have one, and a repository without commits can't branch.
    const project = options.projectId ? this.projects?.get(options.projectId) : undefined;
    const worktreeFrom =
      options.worktreeFrom ??
      (project && !options.shared && !options.teamId && !options.parentId && (await hasCommits(project.path)) ? project.path : undefined);

    const id = randomUUID();
    const session: Session = {
      info: {
        id,
        agent,
        title: options.title ?? options.role ?? DEFAULT_TITLE,
        status: "starting",
        createdAt: new Date().toISOString(),
        archived: false,
        skills: [...new Set(skills)],
        mcpServers: [...new Set(mcpServers)],
        ...(options.teamId ? { teamId: options.teamId } : {}),
        ...(options.role ? { role: options.role } : {}),
        ...(options.parentId ? { parentId: options.parentId } : {}),
        ...((options.orchestrate || options.split) && !options.parentId ? { orchestrate: true } : {}),
        ...(options.split && !options.parentId ? { split: true } : {}),
        ...(options.orchestrate && !options.parentId && options.budgetUsd ? { budgetUsd: options.budgetUsd } : {}),
        ...(worktreeFrom ? { branch: branchName(options.title ?? agent, id) } : {}),
        ...(options.projectId ? { projectId: options.projectId } : {}),
        ...(options.scheduleId ? { scheduleId: options.scheduleId } : {}),
        ...(options.reviewOf ? { reviewOf: options.reviewOf } : {}),
      },
      ...(options.instructions ? { instructions: options.instructions } : {}),
      events: [],
      cwd: "",
      pending: new Map(),
      costBase: 0,
    };
    session.cwd = this.cwdFor(this.workspacesDir, session.info);
    // A node makes its own workspace folder when the agent starts there.
    if (worktreeFrom) await addWorktree(worktreeFrom, session.cwd, session.info.branch!);
    else if (node === LOCAL_NODE) await mkdir(session.cwd, { recursive: true });
    if (session.info.skills.length > 0) {
      const target = this.agents.get(agent)!.skillsDir ?? FALLBACK_SKILLS_DIR;
      await this.skills!.copyInto(session.info.skills, session.cwd, target);
    }
    this.sessions.set(id, session);
    this.save(session);
    log("info", "session starting", { id, agent });

    session.ready = this.startAgent(session)
      .then(() => {
        if (session.info.status === "starting") this.setStatus(session, "idle");
      })
      .catch(() => {});

    return { ...session.info };
  }

  /**
   * `attachments` are workspace-relative paths, usually files the user just uploaded.
   * `from` is the lead session when a lead agent writes to its helper.
   */
  prompt(sessionId: string, text: string, attachments: string[] = [], from?: string): void {
    const session = this.require(sessionId);
    if (!attachments.every(isSafeRelativePath)) {
      throw new KervanError("bad_message", "attachments must be paths inside the workspace");
    }
    if (session.info.status === "running" || session.info.status === "waiting") {
      throw new KervanError("session_busy", "the agent is still answering");
    }
    const node = this.nodeFor(session.info);
    if (!session.process && node !== LOCAL_NODE && !this.nodes?.isConnected(node)) {
      // Leave the session as it is; it can continue once the node is back.
      throw new KervanError("node_offline", `node '${node}' is offline; the session continues when it reconnects`);
    }
    const resumable = !session.process && session.agentSessionId !== undefined;
    if (session.info.status !== "idle" || (!session.process && !resumable)) {
      throw new KervanError("session_unavailable", `session is ${session.info.status}`);
    }

    if (session.info.title === DEFAULT_TITLE || session.info.title === OLD_DEFAULT_TITLE) {
      const line = text.trim().split("\n")[0].replace(/[*_`#>~]/g, "").trim();
      session.info.title = line.length > TITLE_CHARS ? `${line.slice(0, TITLE_CHARS - 1)}…` : line;
    }
    const firstMessage = !session.events.some((event) => event.kind === "user_message");
    this.record(session, {
      kind: "user_message",
      text,
      ...(attachments.length > 0 ? { attachments } : {}),
      ...(from ? { from } : {}),
    });
    const messageSeq = session.events.length;
    this.setStatus(session, "running");
    this.startTurnTimer(session);
    const note = session.note;
    delete session.note;

    (async () => {
      await this.checkpoint(session, messageSeq);
      if (!session.process) {
        await this.startAgent(session, true);
        this.record(session, {
          kind: "notice",
          text: this.isTerminal(session)
            ? "The terminal agent restarted; it doesn't remember the earlier conversation."
            : "The agent restarted; the conversation continues where it left off.",
        });
      }
      // A terminal agent would receive the preface as typed input, so it gets none.
      const terminal = this.isTerminal(session);
      const preface = [firstMessage && !terminal ? await this.preface(session) : undefined, terminal ? undefined : note]
        .filter(Boolean)
        .join("\n\n") || undefined;
      const stopReason = await session.process!.prompt(text, attachments.map((path) => join(session.cwd, path)), preface);
      this.record(session, { kind: "turn_end", stopReason });
    })()
      .catch((error: unknown) => {
        this.record(session, { kind: "error", message: error instanceof Error ? error.message : String(error) });
      })
      .finally(() => {
        clearTimeout(session.turnTimer);
        if (session.info.status === "running" || session.info.status === "waiting") this.setStatus(session, "idle");
      });
  }

  /** Helpers only: the user isn't watching them, so a turn that runs away is stopped. */
  private startTurnTimer(session: Session): void {
    const minutes = this.limits.helperTurnMinutes;
    if (!session.info.parentId || minutes <= 0) return;
    session.turnTimer = setTimeout(() => {
      if (session.info.status !== "running" && session.info.status !== "waiting") return;
      this.record(session, { kind: "notice", text: `The turn time limit (${minutes} min) ran out; the helper was stopped.` });
      void this.cancel(session.info.id);
    }, minutes * 60_000);
  }

  /** Starts one session per role, all sharing the team's folder. */
  async createTeam(title: string, roleIds: string[]): Promise<TeamInfo> {
    const roles = roleIds.map((id) => this.roles?.get(id) ?? fail(`no role named '${id}'`));
    // Checked first, so a node that's away doesn't leave half a team.
    for (const role of roles) this.requireOnline(nodeOf(this.agents.get(role.agent)));
    const team: StoredTeam = { id: randomUUID(), title: title.trim(), createdAt: new Date().toISOString() };
    this.teams.set(team.id, team);
    this.store.saveTeam(team);
    for (const role of roles) {
      await this.create(role.agent, role.skills, role.mcpServers, {
        teamId: team.id,
        role: role.name,
        instructions: role.instructions,
        orchestrate: role.lead === true && this.orchestra !== undefined,
        ...(role.lead && role.budgetUsd ? { budgetUsd: role.budgetUsd } : {}),
      });
    }
    const info = this.teamInfo(team);
    this.broadcast({ type: "team.updated", team: info });
    return info;
  }

  listTeams(): TeamInfo[] {
    return [...this.teams.values()].map((team) => this.teamInfo(team));
  }

  private teamInfo(team: StoredTeam): TeamInfo {
    const members = [...this.sessions.values()].filter((s) => s.info.teamId === team.id).map((s) => s.info);
    return { ...team, sessionIds: members.sort((a, b) => a.createdAt.localeCompare(b.createdAt)).map((s) => s.id) };
  }

  /** Team members share one folder so they see each other's files; helpers work in their lead's. */
  private cwdFor(root: string, info: SessionInfo): string {
    // On a node: a key the node resolves inside its own workspaces folder. Helpers there can't reach
    // their lead's folder on this server, so they get their own.
    if (this.nodeFor(info) !== LOCAL_NODE) return info.teamId ? `team-${info.teamId}` : info.id;
    if (info.branch) return join(root, `worktree-${info.id}`);
    const project = info.projectId ? this.projects?.get(info.projectId) : undefined;
    if (project) return project.path;
    if (info.teamId) return join(root, `team-${info.teamId}`);
    return join(root, info.parentId ?? info.id);
  }

  /** start_helper can pick from these. */
  helperChoices(): { agents: { id: string; name: string }[]; roles: { id: string; name: string; agent: string }[] } {
    return {
      agents: this.agentDetails,
      roles: (this.roles?.list() ?? []).map(({ id, name, agent }) => ({ id, name, agent })),
    };
  }

  /** A lead agent starts a helper in its own folder and gives it its first task. */
  async startHelper(
    leadId: string,
    request: { name: string; task: string; agent?: string; role?: string; isolate?: boolean },
  ): Promise<HelperSummary> {
    const lead = this.require(leadId);
    if (!lead.info.orchestrate) throw new KervanError("bad_message", "this session can't start helpers");
    this.requireBudget(lead);
    const max = this.limits.maxHelpers;
    if (this.helperSessions(leadId).length >= max) {
      throw new KervanError("bad_message", `at most ${max} helpers; message or reuse one you have`);
    }
    const role = request.role === undefined ? undefined : (this.roles?.get(request.role) ?? fail(`no role named '${request.role}'`));
    const agent = role?.agent ?? request.agent ?? fail("give an agent or a role (see list_agents)");
    const remoteNode = nodeOf(this.agents.get(agent));
    const remote = remoteNode !== LOCAL_NODE;
    const isolated = !remote && request.isolate !== false && (await hasCommits(lead.cwd));
    const info = await this.create(agent, role?.skills ?? [], role?.mcpServers ?? [], {
      title: request.name.trim().slice(0, TITLE_CHARS),
      parentId: leadId,
      ...(lead.info.teamId ? { teamId: lead.info.teamId } : {}),
      ...(role ? { role: role.name, instructions: role.instructions } : {}),
      ...(isolated ? { worktreeFrom: lead.cwd } : {}),
    });
    const helper = this.require(info.id);
    await helper.ready;
    if (helper.info.status !== "idle") throw new KervanError("bad_message", `helper didn't start: ${helper.info.error ?? helper.info.status}`);
    this.prompt(info.id, request.task, [], leadId);
    const note = remote
      ? `This helper runs on node '${remoteNode}' in a folder of its own there; it can't see your files, so put what it needs in the task and get results from its reply.`
      : request.isolate !== false && !isolated
        ? "Your folder is not a git repository with a commit, so this helper works in your folder, not on a branch."
        : undefined;
    return { ...this.helperSummary(helper), ...(note ? { note } : {}) };
  }

  messageHelper(leadId: string, helperId: string, text: string): void {
    this.requireBudget(this.require(leadId));
    this.requireHelper(leadId, helperId);
    this.prompt(helperId, text, [], leadId);
  }

  /** What an isolated helper changed on its branch so far. */
  async helperDiff(leadId: string, helperId: string): Promise<{ stat: string; patch: string }> {
    const lead = this.require(leadId);
    const helper = this.requireBranch(leadId, helperId);
    return branchDiff(lead.cwd, helper.cwd, helper.info.branch!, helper.info.title);
  }

  /** Brings an isolated helper's work into the lead's folder; a conflict leaves both untouched. */
  async mergeHelper(leadId: string, helperId: string): Promise<MergeResult> {
    const lead = this.require(leadId);
    const helper = this.requireBranch(leadId, helperId);
    if (!this.isDone(helper)) throw new KervanError("session_busy", "the helper is still working; wait for it first");
    const result = await mergeBranch(lead.cwd, helper.cwd, helper.info.branch!, helper.info.title);
    this.record(
      helper,
      result.merged
        ? { kind: "notice", text: `${lead.info.title} merged this helper's branch (${helper.info.branch}).` }
        : { kind: "notice", text: `The merge conflicted: ${result.conflicts.join(", ") || result.message}` },
    );
    return result;
  }

  private requireBranch(leadId: string, helperId: string): Session {
    const helper = this.requireHelper(leadId, helperId);
    if (!helper.info.branch) throw new KervanError("bad_message", "this helper works in your folder, not on a branch of its own");
    return helper;
  }

  /** What a lead and all its helpers have spent, from what their agents reported. */
  crewCost(leadId: string): number {
    const crew = [this.require(leadId), ...this.helperSessions(leadId)];
    return crew.reduce((sum, s) => sum + (s.info.usage?.costUsd ?? 0), 0);
  }

  private requireBudget(lead: Session): void {
    const budget = lead.info.budgetUsd;
    if (budget !== undefined && this.crewCost(lead.info.id) >= budget) {
      throw new KervanError("bad_message", `the budget of $${budget} for you and your helpers is used up; finish with what you have`);
    }
  }

  /**
   * Changes one of the agent's session settings (e.g. its model). Without a running agent the choice
   * is kept and applied when the agent next starts.
   */
  async setConfig(sessionId: string, configId: string, value: string): Promise<void> {
    const session = this.require(sessionId);
    const option = session.info.config?.find((o) => o.id === configId) ?? fail(`this agent has no setting '${configId}'`);
    if (!option.choices.some((c) => c.value === value)) fail(`'${value}' is not one of the choices for ${option.name}`);
    if (session.process?.setConfig) {
      this.updateConfig(session, await session.process.setConfig(configId, value));
    } else {
      this.updateConfig(session, session.info.config!.map((o) => (o.id === configId ? { ...o, value } : o)));
    }
  }

  private updateConfig(session: Session, options: ConfigOption[]): void {
    session.info.config = options;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  private async restoreConfig(session: Session, chosen: ConfigOption[]): Promise<void> {
    for (const wanted of chosen) {
      const live = session.info.config?.find((o) => o.id === wanted.id);
      if (!live || live.value === wanted.value || !live.choices.some((c) => c.value === wanted.value)) continue;
      try {
        this.updateConfig(session, await session.process!.setConfig!(wanted.id, wanted.value));
      } catch (error) {
        log("warn", "couldn't restore a setting", { id: session.info.id, option: wanted.id, error: String(error) });
      }
    }
  }

  /** Records what the agent reported and, past a lead's budget, stops the lead and its helpers once. */
  private updateUsage(session: Session, usage: { used: number; size: number; costUsd?: number }): void {
    const cost = usage.costUsd === undefined ? session.info.usage?.costUsd : session.costBase + usage.costUsd;
    const spentNow = (cost ?? 0) - (session.info.usage?.costUsd ?? 0);
    if (spentNow > 0) this.store.logUsage(session.info.id, session.info.agent, spentNow);
    session.info.usage = {
      contextUsed: usage.used,
      contextSize: usage.size,
      ...(cost !== undefined ? { costUsd: Math.round(cost * 10_000) / 10_000 } : {}),
    };
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });

    const lead = session.info.parentId ? this.sessions.get(session.info.parentId) : session;
    const budget = lead?.info.budgetUsd;
    if (!lead || budget === undefined || lead.budgetSpent) return;
    const spent = this.crewCost(lead.info.id);
    if (spent < budget) return;
    lead.budgetSpent = true;
    this.record(lead, {
      kind: "notice",
      text: `Budget used up: $${spent.toFixed(2)} of $${budget}. The lead and its helpers were stopped; no new helpers can start.`,
    });
    for (const member of [lead, ...this.helperSessions(lead.info.id)]) void this.cancel(member.info.id);
  }

  /** Resolves when the helper's turn is over, or after `timeoutMs` with `done: false`. */
  async waitForHelper(leadId: string, helperId: string, timeoutMs: number): Promise<HelperSummary> {
    const helper = this.requireHelper(leadId, helperId);
    if (!this.isDone(helper)) {
      await new Promise<void>((resolve) => {
        const finish = () => {
          clearTimeout(timer);
          unsubscribe();
          resolve();
        };
        const timer = setTimeout(finish, timeoutMs);
        const unsubscribe = this.subscribe((message) => {
          if (message.type === "session.updated" && message.session.id === helperId && this.isDone(helper)) finish();
        });
      });
    }
    return this.helperSummary(helper);
  }

  helpers(leadId: string): HelperSummary[] {
    return this.helperSessions(leadId).map((helper) => this.helperSummary(helper));
  }

  /** Stops the helper's turn and its agent; a later message starts it again where it left off. */
  async stopHelper(leadId: string, helperId: string): Promise<void> {
    const helper = this.requireHelper(leadId, helperId);
    await this.cancel(helperId);
    this.rest(helper);
  }

  /**
   * Stops an idle helper's agent so it stops holding memory. Its conversation, folder and branch stay; the next
   * message resumes the agent session where it left off (the same path as after a server restart).
   */
  private rest(session: Session): void {
    this.clearIdleTimer(session.info.id);
    if (!session.process || !session.info.parentId || this.shuttingDown) return;
    if (!["idle", "error"].includes(session.info.status) || session.pending.size > 0) return;
    session.process.close();
    session.process = undefined;
    session.info.resting = true;
    this.record(session, { kind: "notice", text: "Resting: its agent was stopped while idle. The next message starts it again where it left off." });
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  private clearIdleTimer(sessionId: string): void {
    const timer = this.idleTimers.get(sessionId);
    if (timer) clearTimeout(timer);
    this.idleTimers.delete(sessionId);
  }

  /** A helper that goes idle rests after a while; any other status cancels that. */
  private watchIdle(session: Session): void {
    if (!session.info.parentId) return;
    this.clearIdleTimer(session.info.id);
    const minutes = this.limits.helperIdleMinutes;
    if (session.info.status !== "idle" || !session.process || minutes <= 0) return;
    const timer = setTimeout(() => this.rest(session), minutes * 60_000);
    timer.unref();
    this.idleTimers.set(session.info.id, timer);
  }

  /** A lead that stops, or is archived, takes its helpers with it: their turns end and their agents rest. */
  private async stopHelpersOf(leadId: string): Promise<void> {
    for (const helper of this.helperSessions(leadId)) {
      await this.cancel(helper.info.id).catch(() => {});
      this.rest(helper);
    }
  }

  private helperSessions(leadId: string): Session[] {
    return [...this.sessions.values()].filter((s) => s.info.parentId === leadId);
  }

  private requireHelper(leadId: string, helperId: string): Session {
    const helper = this.sessions.get(helperId);
    if (!helper || helper.info.parentId !== leadId) throw new KervanError("unknown_session", `no helper '${helperId}'`);
    return helper;
  }

  private isDone(session: Session): boolean {
    return !["starting", "running", "waiting"].includes(session.info.status);
  }

  private helperSummary(helper: Session): HelperSummary {
    const reply = lastReply(helper.events);
    return {
      helperId: helper.info.id,
      name: helper.info.title,
      agent: helper.info.agent,
      status: helper.info.status,
      done: this.isDone(helper),
      ...(reply ? { reply: reply.length > REPLY_CHARS ? `${reply.slice(0, REPLY_CHARS - 1)}…` : reply } : {}),
      ...(helper.info.branch ? { branch: helper.info.branch } : {}),
      ...(helper.info.usage?.costUsd !== undefined ? { costUsd: helper.info.usage.costUsd } : {}),
      ...(helper.info.error ? { error: helper.info.error } : {}),
    };
  }

  rename(sessionId: string, title: string): void {
    const session = this.require(sessionId);
    session.info.title = title.trim();
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  /** Set on a lead, it covers its helpers too: a task that stalls on a helper's question isn't on auto-approve. */
  setAutoApprove(sessionId: string, enabled: boolean): void {
    const session = this.require(sessionId);
    if (session.info.parentId) throw new KervanError("bad_message", "a helper follows its lead's auto-approve");
    if (this.isTerminal(session)) throw new KervanError("bad_message", "terminal agents don't ask for approval");
    if (Boolean(session.info.autoApprove) === enabled) return;
    if (enabled) session.info.autoApprove = true;
    else delete session.info.autoApprove;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
    this.record(session, {
      kind: "notice",
      text: enabled
        ? "Auto-approve is on: the agent only stops to ask before major changes."
        : "Auto-approve is off: the agent asks before each action again.",
    });
    if (!enabled) return;
    for (const member of [session, ...this.helperSessions(sessionId)]) {
      for (const [requestId, { request }] of [...member.pending]) {
        const allow = this.autoAnswer(member, request);
        if (allow) this.resolvePermission(member, requestId, allow);
      }
    }
  }

  /**
   * Archiving can also take away a project session's worktree; its work stays committed on its branch.
   * Unarchiving puts the worktree back.
   */
  async archive(sessionId: string, archived: boolean, removeWorktree = false): Promise<void> {
    const session = this.require(sessionId);
    if (archived && removeWorktree) {
      const repo = this.worktreeRepo(session);
      if (!repo) throw new KervanError("bad_message", "this session has no worktree of its own");
      if (session.info.status === "running" || session.info.status === "waiting") {
        throw new KervanError("session_busy", "stop the session before removing its worktree");
      }
      if (existsSync(session.cwd)) {
        session.process?.close();
        session.process = undefined;
        await removeWorktreeAt(repo, session.cwd, session.info.title).catch((error) => {
          throw new KervanError("bad_message", `couldn't remove the worktree: ${error instanceof Error && "stderr" in error ? String((error as { stderr: unknown }).stderr).trim() : String(error)}`);
        });
        this.record(session, { kind: "notice", text: `Worktree removed; the work stays on branch ${session.info.branch}.` });
      }
    }
    if (!archived) await this.ensureWorktree(session);
    if (archived) await this.stopHelpersOf(sessionId);
    session.info.archived = archived;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
  }

  /** The repository a project session's worktree belongs to; undefined for anything else. */
  private worktreeRepo(session: Session): string | undefined {
    if (!session.info.branch || !session.info.projectId || session.info.parentId) return undefined;
    return this.projects?.get(session.info.projectId)?.path;
  }

  /** A project session whose worktree was removed gets it back, on its branch, before it runs again. */
  private async ensureWorktree(session: Session): Promise<void> {
    const repo = this.worktreeRepo(session);
    if (!repo || existsSync(session.cwd)) return;
    await restoreWorktree(repo, session.cwd, session.info.branch!);
  }

  search(query: string): SearchHit[] {
    return this.store.search(query);
  }

  /** Answers a pending permission request with one of the options the agent offered. */
  respond(sessionId: string, requestId: string, optionId: string): void {
    const session = this.require(sessionId);
    const pending = session.pending.get(requestId);
    if (!pending) throw new KervanError("unknown_request", `no pending permission request '${requestId}'`);
    if (!pending.optionIds.includes(optionId)) {
      throw new KervanError("bad_message", `'${optionId}' is not one of the offered options`);
    }
    this.resolvePermission(session, requestId, optionId);
  }

  async cancel(sessionId: string): Promise<void> {
    const session = this.require(sessionId);
    // Stopping a lead stops the helpers working for it too.
    if (!session.info.parentId) {
      for (const helper of this.helperSessions(sessionId)) await this.cancel(helper.info.id).catch(() => {});
    }
    if (session.info.status !== "running" && session.info.status !== "waiting") return;
    // ACP: a cancelling client must answer its open permission requests with "cancelled".
    for (const requestId of [...session.pending.keys()]) this.resolvePermission(session, requestId, null);
    await session.process?.cancel();
  }

  /** Shutdown: stop the agents but leave the stored status alone, so the next start recovers. */
  closeAll(): void {
    this.shuttingDown = true;
    for (const id of [...this.idleTimers.keys()]) this.clearIdleTimer(id);
    this.terminals.closeAll();
    this.scheduler?.stop();
    for (const session of this.sessions.values()) {
      session.info.status = "closed";
      for (const pending of session.pending.values()) pending.resolve(null);
      session.pending.clear();
      session.process?.close();
    }
  }

  /**
   * Told to the agent before the first message, unseen by the user: which skills this session has and
   * where. Agents that load skills from their own folder get it too, in case that folder isn't trusted.
   */
  private async preface(session: Session): Promise<string | undefined> {
    const lead = session.info.parentId ? this.sessions.get(session.info.parentId) : undefined;
    const project = session.info.projectId ? this.projects?.get(session.info.projectId) : undefined;
    const parts = [
      project?.instructions ? `[Kervan] Project "${project.name}" — instructions from the user:\n${project.instructions}` : undefined,
      project ? this.mapPreface(project) : undefined,
      lead
        ? `[Kervan] You are a helper agent named "${session.info.title}", started by the lead agent "${lead.info.title}". ` +
          "Messages come from the lead, not the user, and your final answer each turn goes back to it: " +
          "end with a short summary of what you did, which files you changed and anything left open."
        : undefined,
      lead && session.info.branch
        ? `[Kervan] You work in your own git worktree on branch ${session.info.branch}; your changes stay there until ` +
          "the lead merges them. Commit when it helps; anything uncommitted is committed for you when the lead merges."
        : undefined,
      session.instructions && !lead ? `[Kervan] Your role in this team: ${session.info.role}.\n${session.instructions}` : undefined,
      session.instructions && lead ? `[Kervan] Your role: ${session.info.role}.\n${session.instructions}` : undefined,
      session.info.orchestrate
        ? "[Kervan] You can hand subtasks to helper agents with the `kervan` MCP tools: list_agents, start_helper, " +
          `message_helper, wait_for_helper, list_helpers, stop_helper, helper_diff, merge_helper (up to ${this.limits.maxHelpers} helpers). ` +
          "They can't see this conversation, so give each a self-contained task. Start independent tasks together, " +
          "then wait for their replies and check their work before you report back. If your folder is a git repository " +
          "with a commit, each helper works on its own branch in a separate worktree: look at its work with helper_diff " +
          "and bring it in with merge_helper. Otherwise helpers work in your folder."
        : undefined,
      session.info.split
        ? "[Kervan] Before you start, judge the size of the task. If it has independent parts that are each substantial, " +
          "first show your plan as a short list, then hand each part to a helper with start_helper (in parallel where " +
          "they don't depend on each other), keep the rest for yourself, and wait for them, check their work and bring it " +
          "together before you answer. If the task is small or its parts depend on each other, do it yourself without helpers."
        : undefined,
      session.info.budgetUsd !== undefined
        ? `[Kervan] Budget for you and your helpers together: $${session.info.budgetUsd}. Everything stops when it is used up.`
        : undefined,
      (session.info.teamId || session.info.parentId || session.info.orchestrate || project) && !session.info.branch
        ? "[Kervan] Other agents may work in this same folder; check files before overwriting them."
        : undefined,
      await this.skillPreface(session),
    ].filter(Boolean);
    return parts.length > 0 ? parts.join("\n\n") : undefined;
  }

  /** The project map, so the agent goes to the part of the repository its task is about instead of reading all of it. */
  private mapPreface(project: ProjectInfo): string | undefined {
    const text = this.projects?.mapText(project.id);
    if (!text) return undefined;
    const since = project.map?.commit
      ? ` It was made at commit ${project.map.commit.slice(0, 12)}; \`git log --stat ${project.map.commit.slice(0, 12)}..HEAD\` shows what changed since.`
      : "";
    return (
      "[Kervan] Project map, written by an agent that scanned this repository earlier. Use it to go straight to the files " +
      "your task is about; don't scan the whole repository again. Read the files themselves before you change them: " +
      `the map may be out of date.${since}\n\n${text}`
    );
  }

  private async skillPreface(session: Session): Promise<string | undefined> {
    if (session.info.skills.length === 0 || !this.skills) return undefined;
    const dir = this.agents.get(session.info.agent)?.skillsDir ?? FALLBACK_SKILLS_DIR;
    const lines = (await this.skills.describe(session.info.skills)).map(
      ({ name, description }) => `- ${name}: ${description || "(no description)"} — instructions: ${dir}/${name}/SKILL.md`,
    );
    return [
      "[Kervan] Agent Skills available in this session. When a task matches one, read its SKILL.md first and follow it:",
      ...lines,
    ].join("\n");
  }

  /** Snapshots the folder before a message, so its changes can be shown and undone. Local sessions only. */
  private async checkpoint(session: Session, messageSeq: number): Promise<void> {
    if (!this.checkpoints || this.nodeFor(session.info) !== LOCAL_NODE) return;
    try {
      const commit = await this.checkpoints.snapshot(session.info.id, session.cwd, `Kervan: before message ${messageSeq}`);
      this.record(session, { kind: "checkpoint", commit, messageSeq });
    } catch (error) {
      // Not worth stopping the turn for; the Changes panel just has less to show.
      log("warn", "checkpoint failed", { id: session.info.id, error: error instanceof Error ? error.message : String(error) });
    }
  }

  private checkpointsOf(session: Session): { commit: string; messageSeq: number }[] {
    return session.events.flatMap((e) => (e.kind === "checkpoint" ? [{ commit: e.commit, messageSeq: e.messageSeq }] : []));
  }

  private requireLocal(session: Session): Checkpoints {
    if (!this.checkpoints) throw new KervanError("bad_message", "this server keeps no checkpoints");
    if (this.nodeFor(session.info) !== LOCAL_NODE) {
      throw new KervanError("bad_message", "changes can only be followed for agents on this server, not on a node");
    }
    return this.checkpoints;
  }

  /** What the agent changed: since the session's first message, or since the last one. */
  async changes(sessionId: string, since: "session" | "turn" = "session"): Promise<ChangeSet> {
    const session = this.require(sessionId);
    const checkpoints = this.requireLocal(session);
    const all = this.checkpointsOf(session);
    const from = since === "turn" ? all.at(-1) : all[0];
    const branch = await repositoryBranch(session.cwd);
    const repository = { repository: branch !== undefined, ...(branch ? { branch } : {}) };
    if (!from) return { files: [], patch: "", truncated: false, ...repository };
    const found = await checkpoints.changes(session.info.id, session.cwd, from.commit).catch(gitFailure);
    return { ...found, sinceSeq: from.messageSeq, ...repository };
  }

  /**
   * Puts files back as they were before the user message `seq`: all of them (rewinding the session's
   * work to that point) or just `paths`. The agent is told with the next message.
   */
  async revert(sessionId: string, seq: number, paths?: string[]): Promise<string[]> {
    const session = this.require(sessionId);
    const checkpoints = this.requireLocal(session);
    if (paths && !paths.every(isSafeRelativePath)) throw new KervanError("bad_message", "paths must be inside the workspace");
    if (session.info.status === "running" || session.info.status === "waiting") {
      throw new KervanError("session_busy", "stop the agent before putting files back");
    }
    const point = this.checkpointsOf(session).find((c) => c.messageSeq === seq);
    if (!point) throw new KervanError("bad_message", "there is no checkpoint for that message");
    const restored = await checkpoints.restore(session.info.id, session.cwd, point.commit, paths).catch(gitFailure);
    const message = session.events.find((e) => e.seq === seq);
    const quoted = message?.kind === "user_message" ? message.text.trim().split("\n")[0].slice(0, 120) : "";
    if (paths) {
      this.record(session, { kind: "notice", text: `${restored.length} ${restored.length === 1 ? "file" : "files"} reverted: ${restored.slice(0, 5).join(", ")}${restored.length > 5 ? "…" : ""}` });
      session.note = `[Kervan] The user reverted these files to how they were before their message "${quoted}": ${restored.join(", ")}. Read them again before you change them.`;
    } else {
      this.record(session, { kind: "notice", text: `Files rewound to before the message "${quoted}" (${restored.length} ${restored.length === 1 ? "file" : "files"}).` });
      session.note =
        `[Kervan] The user rewound the folder to how it was before their message "${quoted}". ` +
        "Everything you changed after that point is gone; work from the files as they are now.";
    }
    return restored;
  }

  /** Commits everything in the session's folder to its own git repository. */
  async commit(sessionId: string, message: string): Promise<string> {
    const session = this.require(sessionId);
    this.requireLocal(session);
    if ((await repositoryBranch(session.cwd)) === undefined) throw new KervanError("bad_message", "this folder is not a git repository");
    try {
      const summary = await commitAll(session.cwd, message.trim());
      this.record(session, { kind: "notice", text: `Committed: ${summary}` });
      return summary;
    } catch (error) {
      const text = error instanceof Error && "stderr" in error ? String((error as { stderr: unknown }).stderr).trim() : String(error instanceof Error ? error.message : error);
      throw new KervanError("bad_message", text === "nothing to commit" ? "nothing to commit" : `git commit failed: ${text}`);
    }
  }

  /** Puts the session's work up for review on a branch of its own; see openPullRequest. */
  async pullRequest(sessionId: string, title: string, body: string): Promise<PullRequestInfo> {
    const session = this.require(sessionId);
    this.requireLocal(session);
    const result = await openPullRequest(session.cwd, { title: title.trim(), body, sessionId });
    this.record(session, {
      kind: "notice",
      text: result.created ? `Opened a pull request: ${result.url}` : `Pushed ${result.branch} for a pull request into ${result.base}`,
    });
    return result;
  }

  /**
   * A second opinion: `agent` reviews the session's changes in a session of its own, on a copy of the files (so it
   * can't touch the originals), with the diff in CHANGES.diff and the project's instructions in its prompt.
   */
  async review(sessionId: string, agent: string): Promise<SessionInfo> {
    const session = this.require(sessionId);
    this.requireLocal(session);
    if (!this.agents.has(agent)) throw new KervanError("unknown_agent", `no agent named '${agent}'`);
    if (nodeOf(this.agents.get(agent)) !== LOCAL_NODE) throw new KervanError("bad_message", "a reviewer must run on this server");
    const changes = await this.changes(sessionId, "session");
    if (changes.files.length === 0) throw new KervanError("bad_message", "nothing to review: this session hasn't changed any files yet");

    const title = `Review: ${session.info.title}`.slice(0, 120);
    const info = await this.create(agent, [], [], { title, reviewOf: sessionId });
    const reviewer = this.require(info.id);
    // Heavy, rebuildable or private folders stay behind; the copy is for reading.
    const skip = new Set([".git", "node_modules", ".build", "build", "dist", ".next", "target", ".venv", "__pycache__"]);
    await cp(session.cwd, reviewer.cwd, { recursive: true, force: true, filter: (from) => !skip.has(from.split("/").pop() ?? "") });
    await writeFile(join(reviewer.cwd, "CHANGES.diff"), changes.patch);

    const project = session.info.projectId ? this.projects?.get(session.info.projectId) : undefined;
    const author = this.agentDetails.find((a) => a.id === session.info.agent)?.name ?? session.info.agent;
    // The title is often the first prompt cut short; the reviewer checks against what was actually asked.
    const asked = session.events
      .filter((event): event is Extract<SessionEvent, { kind: "user_message" }> => event.kind === "user_message" && !event.from)
      .map((event) => event.text.trim())
      .filter(Boolean);
    const request = asked.join("\n\n---\n\n");
    const prompt = [
      `[Kervan] Review the work of the session "${session.info.title}" (${author}). This folder is a copy of its files, and CHANGES.diff holds what it changed (${changes.files.length} files).`,
      request ? `What the user asked for, in their own messages:\n${request.length > 8000 ? `${request.slice(0, 8000)}\n[…]` : request}` : undefined,
      changes.truncated ? "The diff was cut short; read the changed files themselves for the rest." : undefined,
      project?.instructions ? `The project's instructions, which the work should follow:\n${project.instructions}` : undefined,
      "List the problems you find, most severe first. For each: severity (high, medium or low), the file and line, what is wrong and why it matters. Leave out what is fine. If you find nothing wrong, say so in one line.",
      "Don't change any files: this is a copy, and changes here go nowhere.",
    ]
      .filter(Boolean)
      .join("\n\n");

    await reviewer.ready;
    if (reviewer.info.status !== "idle") throw new KervanError("bad_message", reviewer.info.error ?? "the reviewer didn't start");
    this.prompt(info.id, prompt);
    return { ...reviewer.info };
  }

  /**
   * A scheduled task or a board card: a new session that gets `prompt` as soon as its agent is up. Resolves with its id.
   * `files` (on this server's disk) are copied into the session's uploads/ folder and go along with the prompt.
   * `choose` sees the agent's settings before the prompt goes and may name one to change; if it throws, the session is dropped.
   */
  async runTask(task: {
    agent: string;
    title: string;
    prompt: string;
    projectId?: string;
    scheduleId?: string;
    split?: boolean;
    shared?: boolean;
    files?: { source: string; name: string }[];
    choose?: (config: ConfigOption[]) => Promise<{ configId: string; value: string } | undefined>;
  }): Promise<string> {
    const info = await this.create(task.agent, [], [], {
      title: task.title,
      ...(task.split ? { split: true } : {}),
      ...(task.shared ? { shared: true } : {}),
      ...(task.scheduleId ? { scheduleId: task.scheduleId } : {}),
      ...(task.projectId && this.projects?.get(task.projectId) ? { projectId: task.projectId } : {}),
    });
    const session = this.require(info.id);
    await session.ready;
    if (session.info.status !== "idle") throw new Error(session.info.error ?? "the agent didn't start");
    if (task.choose) {
      const change = await task.choose(session.info.config ?? []).catch(async (error: unknown) => {
        await this.archive(info.id, true);
        throw error;
      });
      if (change) {
        // A refused switch shouldn't cost the task; it runs on the agent's default.
        await this.setConfig(info.id, change.configId, change.value).catch((error) =>
          log("warn", "couldn't switch the model", { id: info.id, error: String(error) }),
        );
      }
    }
    const attachments: string[] = [];
    for (const file of task.files ?? []) {
      // Two files named "rapor.pdf": the second becomes "rapor 2.pdf".
      const dot = file.name.lastIndexOf(".");
      const [stem, ext] = dot > 0 ? [file.name.slice(0, dot), file.name.slice(dot)] : [file.name, ""];
      let path = `uploads/${file.name}`;
      for (let n = 2; attachments.includes(path); n++) path = `uploads/${stem} ${n}${ext}`;
      await placeFile(this, info.id, path, file.source);
      attachments.push(path);
    }
    this.prompt(info.id, task.prompt, attachments);
    return info.id;
  }

  /** Everything the agent said since the last message it was given. */
  reply(sessionId: string): string {
    return lastReply(this.require(sessionId).events);
  }

  /** What agents spent in the last `days` days, by local day in `timeZone`, and the sessions that spent most. */
  usageReport(days: number, timeZone: string, now = new Date()): UsageReport {
    try {
      new Intl.DateTimeFormat("en", { timeZone });
    } catch {
      throw new KervanError("bad_message", `unknown time zone '${timeZone}'`);
    }
    const since = new Date(now.getTime() - days * 24 * 60 * 60_000);
    const byDay = new Map<string, { date: string; agent: string; costUsd: number }>();
    const bySession = new Map<string, number>();
    for (const row of this.store.usageSince(since)) {
      const date = localParts(new Date(row.at), timeZone).date;
      const key = `${date}\u0000${row.agent}`;
      const day = byDay.get(key) ?? { date, agent: row.agent, costUsd: 0 };
      day.costUsd += row.costUsd;
      byDay.set(key, day);
      bySession.set(row.sessionId, (bySession.get(row.sessionId) ?? 0) + row.costUsd);
    }
    const round = (n: number) => Math.round(n * 10_000) / 10_000;
    return {
      days: [...byDay.values()].map((d) => ({ ...d, costUsd: round(d.costUsd) })).sort((a, b) => a.date.localeCompare(b.date)),
      sessions: [...bySession]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 10)
        .map(([sessionId, costUsd]) => ({ sessionId, costUsd: round(costUsd) })),
    };
  }

  /** Starts (or resumes) the session's agent. On failure the session ends up in `error`. */
  private async startAgent(session: Session, resume = false): Promise<void> {
    session.costBase = session.info.usage?.costUsd ?? 0;
    delete session.info.resting;
    await this.ensureWorktree(session).catch((error) => log("warn", "couldn't restore a worktree", { id: session.info.id, error: String(error) }));
    // What the user chose before the agent stopped; a restarted agent may come back on its defaults.
    const chosen = session.info.config ?? [];
    try {
      const process = await this.runner.start({
        command: this.agents.get(session.info.agent)!,
        cwd: session.cwd,
        onEvent: (event) => this.record(session, event),
        onPermission: (request) => this.askPermission(session, request),
        onUsage: (usage) => this.updateUsage(session, usage),
        onConfig: (options) => this.updateConfig(session, options),
        mcpServers: (supportsHttp) => {
          const { servers, skipped } = this.mcp?.toAcp(session.info.mcpServers, supportsHttp) ?? { servers: [], skipped: [] };
          if (skipped.length > 0) {
            this.record(session, { kind: "notice", text: `This agent doesn't support HTTP MCP servers; skipped: ${skipped.join(", ")}` });
          }
          if (session.info.orchestrate && this.orchestra) servers.push(this.orchestra.mcpServer(session.info.id));
          return servers;
        },
        ...(resume ? { resumeSessionId: session.agentSessionId } : {}),
      });
      if (this.shuttingDown) {
        // closeAll ran while this agent was still starting; don't leave it running on its own.
        process.close();
        return;
      }
      session.process = process;
      session.agentSessionId = process.sessionId;
      this.save(session);
      await this.restoreConfig(session, chosen);
      process.exited.then(() => this.onExit(session, process));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log("error", "agent failed to start", { id: session.info.id, resume, error: message });
      this.record(session, { kind: "error", message: `The agent couldn't start: ${message}` });
      this.setStatus(session, "error", message);
      throw error;
    }
  }

  /**
   * Brings a session loaded from disk to a consistent state: the agent process died with the
   * old server, so close what it left open and make the session resumable if possible.
   */
  private recover(session: Session): void {
    const { status } = session.info;
    if (status === "error" || status === "closed") return;

    const resolved = new Set(session.events.flatMap((e) => (e.kind === "permission_resolved" ? [e.requestId] : [])));
    for (const event of session.events) {
      if (event.kind === "permission_request" && !resolved.has(event.requestId)) {
        this.record(session, { kind: "permission_resolved", requestId: event.requestId, outcome: "cancelled" });
      }
    }
    if (status === "running" || status === "waiting") {
      this.record(session, { kind: "turn_end", stopReason: "interrupted" });
    }

    if (session.agentSessionId) {
      if (status !== "idle") this.setStatus(session, "idle");
    } else {
      this.setStatus(session, "error", "agent session id unknown; cannot resume");
    }
  }

  private askPermission(session: Session, request: PermissionRequest): Promise<PermissionDecision> {
    // Choosing "may start helpers" already said yes to Kervan's own tools; don't ask again per call.
    if (session.info.orchestrate && isOrchestraCall(request.title, request.toolKind)) {
      const allow = request.options.find((o) => o.kind === "allow_once") ?? request.options.find((o) => o.kind === "allow_always");
      if (allow) return Promise.resolve(allow.optionId);
    }
    if (this.autoApproves(session)) {
      const allow = this.autoAnswer(session, request);
      if (allow) return Promise.resolve(allow);
      const reason = majorChange(request, session.cwd);
      if (reason) this.record(session, { kind: "notice", text: `Auto-approve stopped to ask: ${reason}.` });
    }
    const requestId = randomUUID();
    return new Promise((resolve) => {
      session.pending.set(requestId, { request, optionIds: request.options.map((o) => o.optionId), resolve });
      this.record(session, { kind: "permission_request", requestId, ...request });
      this.setStatus(session, "waiting");
    });
  }

  private autoApproves(session: Session): boolean {
    const owner = session.info.parentId ? this.sessions.get(session.info.parentId) : session;
    return owner?.info.autoApprove === true;
  }

  /**
   * The option to answer with, or undefined if the user has to decide. Only ever "allow once": "allow always" would
   * have the agent stop asking about that tool for good, including about the major uses of it.
   */
  private autoAnswer(session: Session, request: PermissionRequest): string | undefined {
    if (majorChange(request, session.cwd)) return undefined;
    return request.options.find((o) => o.kind === "allow_once")?.optionId;
  }

  private resolvePermission(session: Session, requestId: string, optionId: PermissionDecision): void {
    const pending = session.pending.get(requestId);
    if (!pending) return;
    session.pending.delete(requestId);
    this.record(
      session,
      optionId
        ? { kind: "permission_resolved", requestId, outcome: "selected", optionId }
        : { kind: "permission_resolved", requestId, outcome: "cancelled" },
    );
    if (session.pending.size === 0 && session.info.status === "waiting") this.setStatus(session, "running");
    pending.resolve(optionId);
  }

  private require(sessionId: string): Session {
    const session = this.sessions.get(sessionId);
    if (!session) throw new KervanError("unknown_session", `no session '${sessionId}'`);
    return session;
  }

  private record(session: Session, body: SessionEventBody): void {
    if (this.shuttingDown) return; // recover() on the next start closes whatever was cut off
    const event = { ...body, seq: session.events.length + 1, at: new Date().toISOString() } as SessionEvent;
    this.store.appendEvent(session.info.id, event);
    this.index(session, event);
    session.events.push(event);
    this.broadcast({ type: "session.event", sessionId: session.info.id, event });
  }

  /** Keeps the search index in step: user messages at once, agent messages as they grow. */
  private index(session: Session, event: SessionEvent): void {
    if (event.kind === "agent_message_chunk") {
      if (session.streaming) session.streaming.text += event.text;
      else session.streaming = { seq: event.seq, role: "agent", text: event.text };
      this.store.indexMessage(session.info.id, session.streaming);
      return;
    }
    if (event.kind !== "agent_thought_chunk") session.streaming = undefined;
    if (event.kind === "user_message") this.store.indexMessage(session.info.id, { seq: event.seq, role: "user", text: event.text });
  }

  private setStatus(session: Session, status: SessionInfo["status"], error?: string): void {
    if (this.shuttingDown) return;
    session.info.status = status;
    if (error) session.info.error = error;
    else delete session.info.error;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
    this.watchIdle(session);
  }

  private save(session: Session): void {
    this.store.saveSession({ info: session.info, agentSessionId: session.agentSessionId, instructions: session.instructions });
  }

  /**
   * The agent process died on its own. A conversation the agent can resume stays usable: the next
   * message starts the agent again where it left off, as after a server restart.
   */
  /** A PTY agent: typed into, never resumed, and given no hidden preface. */
  private isTerminal(session: Session): boolean {
    return this.agents.get(session.info.agent)?.protocol === "pty";
  }

  private onExit(session: Session, process: AgentProcess): void {
    if (session.info.status === "closed" || session.process !== process) return;
    session.process = undefined;
    for (const pending of session.pending.values()) pending.resolve(null);
    session.pending.clear();
    log("warn", "agent process exited", { id: session.info.id });
    if (!session.agentSessionId) {
      this.record(session, { kind: "error", message: "The agent process exited unexpectedly." });
      this.setStatus(session, "error", "agent process exited");
      return;
    }
    this.record(session, {
      kind: "notice",
      text: this.isTerminal(session)
        ? "The terminal agent exited. It restarts with your next message but won't remember the earlier conversation."
        : "The agent process exited unexpectedly. It restarts where it left off with your next message.",
    });
    // A turn in progress settles in prompt(), which then marks the session idle.
    if (session.info.status !== "running" && session.info.status !== "waiting") this.setStatus(session, "idle");
  }

  /** Sends to every connected client. */
  broadcast(message: ServerMessage): void {
    for (const listener of this.listeners) listener(message);
  }
}

/** Everything the agent said since the last message it was given. */
/** A git error in the checkpoint store, as an answer the client gets (instead of a dropped request). */
function gitFailure(error: unknown): never {
  const stderr = error instanceof Error && "stderr" in error ? String((error as { stderr: unknown }).stderr).trim() : "";
  throw new KervanError("bad_message", `checkpoint store: ${stderr || (error instanceof Error ? error.message : String(error))}`);
}

function lastReply(events: SessionEvent[]): string {
  let text = "";
  for (const event of events) {
    if (event.kind === "user_message") text = "";
    else if (event.kind === "agent_message_chunk") text += event.text;
  }
  return text.trim();
}
