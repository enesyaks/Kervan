import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { log } from "./log.ts";
import { KervanError, type ProjectMapInfo } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";

const run = promisify(execFile);

/** The title of the sessions that build maps. */
export const MAP_TITLE = "Project map";

/** What the mapping agent is asked; its final answer becomes the map. */
export const MAP_PROMPT = [
  "Scan this repository once and write a project map for the agents that will work here after you.",
  "They get only your section headings before their task and read the sections they need, so they can go straight",
  "to the files a task touches instead of reading the whole repository again.",
  "Only read: don't change, create or delete any files, and don't install anything.",
  "",
  "Answer with the map alone, in Markdown, at most about 6000 words. Split it into many small sections, one subject",
  "each. Start every section with a heading of the form `## @1a Title — what it answers`, where 1a is its own short",
  "hexadecimal address. The heading is all a reader sees when choosing, so make it specific.",
  "Refer to another section by its address, like →1a, instead of repeating it. Cover:",
  "- What the project is and does, in two or three sentences.",
  "- Languages, frameworks and the commands to install, build, run and test it.",
  "- The layout: each top-level folder and the important files in it, one line each with its path and what it holds.",
  "- One section per service or process: what starts it, and everything it reaches: databases, files, queues, sockets,",
  "  other services, external APIs, with the environment variables and credentials that configure each (names only,",
  "  never values).",
  "- Every API: HTTP routes, WebSocket messages, RPC, CLI commands and webhooks, each with its method and path or name,",
  "  who may call it, what it takes and returns, and the file that handles it.",
  "- How the project behaves: how a request or feature flows through the code, background jobs and schedules, state",
  "  and its transitions, what is retried, timeouts and limits, what happens on failure or restart.",
  "- Where each kind of work lives (e.g. UI, API, data, protocol, configuration) and which files change together.",
  "- Conventions worth following: naming, style, tests, translations, commit habits.",
  "- Anything surprising a newcomer would get wrong.",
  "Use exact paths. Write in terse notes, not sentences. Skip what's obvious from a file name.",
].join("\n");

/**
 * Project maps: a session in the project folder scans the repository once and answers with a map, which is kept
 * beside the project and given to every later session there (see SessionManager.preface).
 */
export class ProjectMaps {
  private readonly sessions: SessionManager;
  /** Mapping session id → project id, until its turn ends. */
  private readonly building = new Map<string, string>();

  constructor(sessions: SessionManager) {
    this.sessions = sessions;
    sessions.subscribe((message) => {
      if (message.type !== "session.updated") return;
      const projectId = this.building.get(message.session.id);
      if (!projectId) return;
      if (message.session.status === "idle") this.settle(message.session.id, projectId);
      else if (message.session.status === "error") this.fail(message.session.id, projectId, message.session.error ?? "the agent stopped");
    });
  }

  private get projects() {
    if (!this.sessions.projects) throw new KervanError("bad_message", "this server has no projects");
    return this.sessions.projects;
  }

  /** Starts (re)building the map with `agent` and returns once it is under way; the project says how it goes. */
  async build(projectId: string, agent: string): Promise<void> {
    const project = this.projects.get(projectId);
    if (!project) throw new KervanError("bad_message", `no project '${projectId}'`);
    if (!this.sessions.agentKinds.includes(agent)) throw new KervanError("unknown_agent", `no agent named '${agent}'`);
    if (project.map?.status === "building") throw new KervanError("bad_message", "the map is already being built");
    const commit = await run("git", ["rev-parse", "HEAD"], { cwd: project.path }).then(
      ({ stdout }) => stdout.trim(),
      () => undefined,
    );
    const map: ProjectMapInfo = { status: "building", agent, ...(commit ? { commit } : {}), updatedAt: new Date().toISOString() };
    this.set(projectId, map);
    try {
      // In the project folder itself: a map of a worktree's branch would be a map of the wrong thing.
      const sessionId = await this.sessions.runTask({ agent, title: MAP_TITLE, prompt: MAP_PROMPT, projectId, shared: true });
      this.building.set(sessionId, projectId);
      this.set(projectId, { ...map, sessionId });
      // The turn may have ended before we knew the session.
      if (this.sessions.list().find((s) => s.id === sessionId)?.status === "idle") this.settle(sessionId, projectId);
    } catch (error) {
      this.set(projectId, { ...map, status: "failed", error: error instanceof Error ? error.message : String(error), updatedAt: new Date().toISOString() });
    }
  }

  /** An idle mapping session either finished its turn, failed it, or hasn't been given it yet. */
  private settle(sessionId: string, projectId: string): void {
    const last = this.sessions.history(sessionId).findLast((e) => e.kind === "turn_end" || e.kind === "error");
    if (last?.kind === "error") this.fail(sessionId, projectId, last.message);
    else if (last?.kind === "turn_end" && last.stopReason !== "end_turn") this.fail(sessionId, projectId, `the agent stopped (${last.stopReason})`);
    else if (last?.kind === "turn_end") void this.done(sessionId, projectId);
  }

  private async done(sessionId: string, projectId: string): Promise<void> {
    if (!this.building.delete(sessionId)) return;
    const map = this.projects.get(projectId)?.map;
    if (!map) return;
    const text = this.sessions.reply(sessionId);
    if (!text) return this.fail(sessionId, projectId, "the agent answered with no map");
    this.set(projectId, { ...map, status: "ready", updatedAt: new Date().toISOString() }, text);
    // Done with: out of the session list, where it would only be noise. Its transcript stays.
    await this.sessions.archive(sessionId, true).catch(() => {});
    log("info", "project mapped", { projectId, sessionId, chars: text.length });
  }

  private fail(sessionId: string, projectId: string, error: string): void {
    this.building.delete(sessionId);
    const map = this.projects.get(projectId)?.map;
    if (map) this.set(projectId, { ...map, status: "failed", error, updatedAt: new Date().toISOString() });
  }

  private set(projectId: string, map: ProjectMapInfo, text?: string): void {
    this.projects.setMap(projectId, map, text);
    this.sessions.broadcast({ type: "projects.updated", projects: this.projects.list() });
  }
}

export function attachProjectMaps(sessions: SessionManager): ProjectMaps {
  const maps = new ProjectMaps(sessions);
  sessions.maps = maps;
  return maps;
}
