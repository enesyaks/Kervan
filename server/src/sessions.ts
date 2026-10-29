import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { AgentRegistry } from "./agents.ts";
import { isSafeRelativePath } from "./files.ts";
import { log } from "./log.ts";
import { KervanError, type AgentDetail, type ConfigOption, type ServerMessage, type TeamInfo, type SessionEvent, type SessionEventBody, type SessionInfo } from "./protocol.ts";
import type { AgentProcess, AgentRunner, PermissionDecision, PermissionRequest } from "./runner.ts";
import type { AgentCatalog } from "./catalog.ts";
import type { McpRegistry } from "./mcp.ts";
import type { SkillLibrary } from "./skills.ts";
import type { EventStore, IndexedMessage, SearchHit, StoredTeam } from "./store.ts";
import type { RoleRegistry } from "./roles.ts";
import type * as acp from "@agentclientprotocol/sdk";
import { isOrchestraCall } from "./orchestra.ts";
import { LOCAL_NODE, nodeOf, type NodeHub } from "./nodes.ts";
import { addWorktree, branchDiff, branchName, hasCommits, mergeBranch, type MergeResult } from "./worktree.ts";

const fail = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/** Where a skill lands in a workspace when the agent has no skills folder of its own. */
const FALLBACK_SKILLS_DIR = ".kervan/skills";

const DEFAULT_TITLE = "Yeni oturum";
const TITLE_CHARS = 60;
/** Per lead, unless configured otherwise; a runaway lead can't fill the server with agents. */
export const MAX_HELPERS = 6;
/** A helper's turn is stopped after this long, unless configured otherwise. */
export const HELPER_TURN_MINUTES = 30;

export interface Limits {
  maxHelpers: number;
  /** 0 turns the limit off. */
  helperTurnMinutes: number;
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
}

interface PendingPermission {
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
    } = {},
  ) {
    this.nodes = extras.nodes;
    this.limits = { maxHelpers: MAX_HELPERS, helperTurnMinutes: HELPER_TURN_MINUTES, ...extras.limits };
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
      ...(nodeOf(agent) !== LOCAL_NODE ? { node: nodeOf(agent) } : {}),
    }));
  }

  /** Tell every client which nodes exist and which are connected. */
  nodesChanged(): void {
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
      if (options.orchestrate) throw new KervanError("bad_message", `a lead must run on this server; '${agent}' runs on node '${node}'`);
      if (skills.length > 0) throw new KervanError("bad_message", `skills aren't available on node '${node}' yet`);
      if (!this.nodes) throw new KervanError("node_offline", `this server doesn't accept nodes, so '${agent}' can't run`);
    }
    if (options.orchestrate && this.agents.get(agent)?.protocol === "pty") {
      throw new KervanError("bad_message", "terminal agents can't use Kervan's tools, so they can't start helpers");
    }

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
        ...(options.orchestrate && !options.parentId ? { orchestrate: true } : {}),
        ...(options.orchestrate && !options.parentId && options.budgetUsd ? { budgetUsd: options.budgetUsd } : {}),
        ...(options.worktreeFrom ? { branch: branchName(options.title ?? agent, id) } : {}),
      },
      ...(options.instructions ? { instructions: options.instructions } : {}),
      events: [],
      cwd: "",
      pending: new Map(),
      costBase: 0,
    };
    session.cwd = this.cwdFor(this.workspacesDir, session.info);
    // A node makes its own workspace folder when the agent starts there.
    if (options.worktreeFrom) await addWorktree(options.worktreeFrom, session.cwd, session.info.branch!);
    else if (node === LOCAL_NODE) await mkdir(session.cwd, { recursive: true });
    if (session.info.skills.length > 0) {
      const target = this.agents.get(agent)!.skillsDir ?? FALLBACK_SKILLS_DIR;
      await this.skills!.copyInto(session.info.skills, join(session.cwd, target));
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

    if (session.info.title === DEFAULT_TITLE) {
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
    this.setStatus(session, "running");
    this.startTurnTimer(session);

    (async () => {
      if (!session.process) {
        await this.startAgent(session, true);
        this.record(session, {
          kind: "notice",
          text: this.isTerminal(session)
            ? "Terminal ajanı yeniden başlatıldı; önceki konuşmayı hatırlamaz."
            : "Ajan yeniden başlatıldı; konuşma kaldığı yerden devam ediyor.",
        });
      }
      // A terminal agent would receive the preface as typed input, so it gets none.
      const preface = firstMessage && !this.isTerminal(session) ? await this.preface(session) : undefined;
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
      this.record(session, { kind: "notice", text: `Tur süresi sınırı (${minutes} dk) doldu; yardımcı durduruldu.` });
      void this.cancel(session.info.id);
    }, minutes * 60_000);
  }

  /** Starts one session per role, all sharing the team's folder. */
  async createTeam(title: string, roleIds: string[]): Promise<TeamInfo> {
    const roles = roleIds.map((id) => this.roles?.get(id) ?? fail(`no role named '${id}'`));
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
        ? { kind: "notice", text: `${lead.info.title} bu yardımcının dalını (${helper.info.branch}) birleştirdi.` }
        : { kind: "notice", text: `Birleştirme çakıştı: ${result.conflicts.join(", ") || result.message}` },
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
      text: `Bütçe doldu: $${spent.toFixed(2)} / $${budget}. Ana ajan ve yardımcıları durduruldu; yeni yardımcı başlatılamaz.`,
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

  async stopHelper(leadId: string, helperId: string): Promise<void> {
    this.requireHelper(leadId, helperId);
    await this.cancel(helperId);
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

  archive(sessionId: string, archived: boolean): void {
    const session = this.require(sessionId);
    session.info.archived = archived;
    this.save(session);
    this.broadcast({ type: "session.updated", session: { ...session.info } });
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
    if (session.info.status !== "running" && session.info.status !== "waiting") return;
    // ACP: a cancelling client must answer its open permission requests with "cancelled".
    for (const requestId of [...session.pending.keys()]) this.resolvePermission(session, requestId, null);
    await session.process?.cancel();
  }

  /** Shutdown: stop the agents but leave the stored status alone, so the next start recovers. */
  closeAll(): void {
    this.shuttingDown = true;
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
    const parts = [
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
      session.info.budgetUsd !== undefined
        ? `[Kervan] Budget for you and your helpers together: $${session.info.budgetUsd}. Everything stops when it is used up.`
        : undefined,
      (session.info.teamId || session.info.parentId || session.info.orchestrate) && !session.info.branch
        ? "[Kervan] Other agents may work in this same folder; check files before overwriting them."
        : undefined,
      await this.skillPreface(session),
    ].filter(Boolean);
    return parts.length > 0 ? parts.join("\n\n") : undefined;
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

  /** Starts (or resumes) the session's agent. On failure the session ends up in `error`. */
  private async startAgent(session: Session, resume = false): Promise<void> {
    session.costBase = session.info.usage?.costUsd ?? 0;
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
            this.record(session, { kind: "notice", text: `Bu ajan HTTP MCP desteklemiyor, atlandı: ${skipped.join(", ")}` });
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
      this.record(session, { kind: "error", message: `Ajan başlatılamadı: ${message}` });
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
    const requestId = randomUUID();
    return new Promise((resolve) => {
      session.pending.set(requestId, { optionIds: request.options.map((o) => o.optionId), resolve });
      this.record(session, { kind: "permission_request", requestId, ...request });
      this.setStatus(session, "waiting");
    });
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
      this.record(session, { kind: "error", message: "Ajan süreci beklenmedik şekilde kapandı." });
      this.setStatus(session, "error", "agent process exited");
      return;
    }
    this.record(session, {
      kind: "notice",
      text: this.isTerminal(session)
        ? "Terminal ajanı kapandı. Bir sonraki mesajınızda yeniden başlatılacak; önceki konuşmayı hatırlamaz."
        : "Ajan süreci beklenmedik şekilde kapandı. Bir sonraki mesajınızda kaldığı yerden yeniden başlatılacak.",
    });
    // A turn in progress settles in prompt(), which then marks the session idle.
    if (session.info.status !== "running" && session.info.status !== "waiting") this.setStatus(session, "idle");
  }

  private broadcast(message: ServerMessage): void {
    for (const listener of this.listeners) listener(message);
  }
}

/** Everything the agent said since the last message it was given. */
function lastReply(events: SessionEvent[]): string {
  let text = "";
  for (const event of events) {
    if (event.kind === "user_message") text = "";
    else if (event.kind === "agent_message_chunk") text += event.text;
  }
  return text.trim();
}
