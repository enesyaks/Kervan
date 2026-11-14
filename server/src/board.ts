import { randomUUID } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Transform, type Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { TooLargeError } from "./files.ts";
import { log } from "./log.ts";
import { suggestModel } from "./modelpick.ts";
import { KervanError, type CardColumn, type CardInfo, type CaseKind, type ConfigOption, type ProjectPM, type ServerMessage, type SessionInfo } from "./protocol.ts";
import type { Role } from "./roles.ts";
import type { SessionManager } from "./sessions.ts";

const COLUMNS: readonly CardColumn[] = ["todo", "working", "needs", "review", "done"];
const MAX_TITLE = 120;
const MAX_PROMPT = 20_000;
const MAX_FILES = 20;
/** A file added to a card: "<upload id>/<name>" under the board's card-files folder. */
const FILE_REF = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(?!\.\.?$)[^/\\\0]+$/;
/** Files uploaded for a card that was never saved are swept after this long. */
const ORPHAN_MS = 24 * 60 * 60_000;
/** Long enough to read the popup and answer it; short enough that a card nobody is watching isn't held up. */
const MODEL_CHOICE_SECONDS = 15;

/** At most this many PM sessions per project work at once; the cards after them wait in To do. */
export const MAX_PM_CASES = 2;
/** A PM's plan for a card, as shown on it. */
const MAX_PLAN = 8_000;
/** Cards a PM opened that nobody has started yet, per project; past this it has to wait for the user. */
export const MAX_PM_PROPOSALS = 5;
/** Cards one PM session may open. */
export const MAX_CASES_PER_PM = 3;
const KINDS: readonly CaseKind[] = ["feature", "security", "fix"];
/** A file, optionally with a line: what a security card's reason has to point at. */
const EVIDENCE = /[\w./-]+\.[A-Za-z0-9]+(:\d+)?/;

/** A setting to change before the card's prompt goes. */
type ConfigChange = { configId: string; value: string };

export interface BoardDeps {
  hasProject: (id: string) => boolean;
  hasAgent: (id: string) => boolean;
  /** Why the agent can't work on the project (an old node, a project that isn't a git repository), if it can't. */
  projectRefusal?: (agent: string, projectId: string) => string | undefined;
  /**
   * Starts a session in the project with the card's prompt and files, after `choose` has seen its settings; resolves with
   * its id once the prompt is sent. With `pm` the session is the project's PM, in that role.
   */
  start: (card: CardInfo, files: { source: string; name: string }[], choose: (config: ConfigOption[]) => Promise<ConfigChange | undefined>, pm?: Role) => Promise<string>;
  /** The project's PM and its role, if it has one. */
  projectPM?: (projectId: string) => { pm: ProjectPM; role: Role } | undefined;
  /** The session as it is now, to catch up after starting. */
  session: (id: string) => SessionInfo | undefined;
  broadcast: (message: ServerMessage) => void;
  modelChoiceSeconds?: number;
}

/**
 * A task board per project. A card is a title and a prompt; moving it to Working starts a session with the prompt,
 * and from then on the card follows its session: waiting for approval → Needs you, a finished turn → Review,
 * archived → Done. Cards live on the server, so every client sees the same board.
 *
 * Files for a card are uploaded before it is saved (it may not exist yet) into card-files/<upload id>/<name>, and
 * copied into the session's uploads/ folder when it starts.
 */
export class Board {
  readonly filesDir: string;
  private readonly file: string;
  private readonly deps: BoardDeps;
  private cards: Map<string, CardInfo>;
  /** Cards waiting to hear which model to use. */
  private readonly choices = new Map<string, { answer: (useDefault: boolean) => void; cancel: () => void }>();
  /** Cards the PM is picking up right now, before their session counts as working. */
  private readonly pickingUp = new Set<string>();

  constructor(file: string, deps: BoardDeps) {
    this.file = file;
    this.deps = deps;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as CardInfo[]) : [];
    for (const card of stored) {
      // The server stopped while the card waited: its prompt never went, so it can simply be started again.
      if (card.modelChoice) {
        delete card.modelChoice;
        card.column = "todo";
      }
    }
    this.cards = new Map(stored.map((card) => [card.id, card]));
    this.filesDir = join(dirname(file), "card-files");
    mkdirSync(this.filesDir, { recursive: true, mode: 0o700 });
    this.sweep();
  }

  /** Keeps an uploaded file for a card about to be saved; resolves with the reference to put in the card's `files`. */
  async stageFile(body: Readable, name: string, maxBytes: number): Promise<{ file: string; size: number }> {
    const file = `${randomUUID()}/${name}`;
    if (!FILE_REF.test(file)) throw new KervanError("bad_message", "file name must not contain a path");
    const dir = join(this.filesDir, dirname(file));
    await mkdir(dir, { mode: 0o700 });
    let size = 0;
    const limit = new Transform({
      transform(chunk: Buffer, _encoding, done) {
        size += chunk.length;
        done(size > maxBytes ? new TooLargeError() : null, chunk);
      },
    });
    try {
      await pipeline(body, limit, createWriteStream(join(this.filesDir, file), { flags: "wx", mode: 0o600 }));
    } catch (error) {
      await rm(dir, { recursive: true, force: true });
      throw error;
    }
    return { file, size };
  }

  /** Every card belongs to a project; an agent that can't work on it is found now, not when the card is started. */
  private refuseProjectWork(agent: string, projectId: string): void {
    const refusal = this.deps.projectRefusal?.(agent, projectId);
    if (refusal) throw new KervanError("bad_message", refusal);
  }

  list(projectId: string): CardInfo[] {
    return [...this.cards.values()].filter((c) => c.projectId === projectId).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  /** A new card (in To do), or new wording for one that hasn't started yet. */
  save(input: Record<string, unknown>): CardInfo {
    const text = (key: string, max: number) => {
      const value = input[key];
      if (typeof value !== "string" || value.trim() === "" || value.length > max) {
        throw new KervanError("bad_message", `${key} must be 1–${max} characters`);
      }
      return value.trim();
    };
    const title = text("title", MAX_TITLE);
    const prompt = text("prompt", MAX_PROMPT);
    const agent = text("agent", 80);
    if (!this.deps.hasAgent(agent)) throw new KervanError("unknown_agent", `no agent named '${agent}'`);
    const split = input.split === true ? { split: true } : {};
    const files = this.files(input.files);
    const now = new Date().toISOString();

    if (typeof input.id === "string") {
      const card = this.require(input.id);
      this.refuseWhileChoosing(card);
      if (card.sessionId) throw new KervanError("bad_message", "a card can't be changed once its session has started");
      this.refuseProjectWork(agent, card.projectId);
      Object.assign(card, { title, prompt, agent, updatedAt: now });
      if (input.split === true) card.split = true;
      else delete card.split;
      if (input.autoApprove === true) card.autoApprove = true;
      else delete card.autoApprove;
      if (input.direct === true) card.direct = true;
      else delete card.direct;
      this.drop((card.files ?? []).filter((f) => !files.includes(f)));
      if (files.length > 0) card.files = files;
      else delete card.files;
      this.changed(card.projectId);
      return card;
    }
    const projectId = text("projectId", 80);
    if (!this.deps.hasProject(projectId)) throw new KervanError("bad_message", `no project '${projectId}'`);
    this.refuseProjectWork(agent, projectId);
    const card: CardInfo = {
      id: randomUUID(),
      projectId,
      title,
      prompt,
      agent,
      ...split,
      ...(input.autoApprove === true ? { autoApprove: true } : {}),
      ...(input.direct === true ? { direct: true } : {}),
      ...(files.length > 0 ? { files } : {}),
      column: "todo",
      createdAt: now,
      updatedAt: now,
    };
    this.cards.set(card.id, card);
    this.changed(projectId);
    this.pickUp(projectId);
    return card;
  }

  /** Moving a card that hasn't started to Working starts its session; other moves just put it there. */
  async move(cardId: string, column: string): Promise<void> {
    if (!COLUMNS.includes(column as CardColumn)) throw new KervanError("bad_message", `column must be one of ${COLUMNS.join(", ")}`);
    const card = this.require(cardId);
    this.refuseWhileChoosing(card);
    if (column === "working" && !card.sessionId) {
      delete card.error;
      this.place(card, "working");
      try {
        const files = (card.files ?? []).map((f) => ({ source: join(this.filesDir, f), name: f.slice(f.indexOf("/") + 1) }));
        // In a project with a PM the card goes to it, unless it was meant for its own agent.
        const lead = card.direct ? undefined : this.deps.projectPM?.(card.projectId);
        card.sessionId = await this.deps.start(card, files, (config) => this.chooseModel(card, config), lead?.role);
        if (lead) card.pm = true;
        card.prompted = true;
      } catch (error) {
        if (!this.cards.has(cardId)) return; // deleted while it waited for its model
        this.place(card, "todo");
        throw new KervanError("bad_message", `couldn't start the session: ${error instanceof Error ? error.message : String(error)}`);
      }
      // The turn may already have moved on while the session started.
      const session = this.deps.session(card.sessionId);
      if (session) this.follow(session);
      this.changed(card.projectId);
      // The session has its copies now; the card keeps the names.
      this.drop(card.files ?? []);
      return;
    }
    if (column === "todo" && card.sessionId) throw new KervanError("bad_message", "a card whose session has started can't go back to To do");
    this.place(card, column as CardColumn);
  }

  /**
   * Starts cards waiting in To do with the project's PM, when it picks them up by itself: the oldest first, and only
   * while fewer than MAX_PM_CASES of its sessions work. Called when a card is added, a card moves, or the PM changes.
   */
  pickUp(projectId: string): void {
    const lead = this.deps.projectPM?.(projectId);
    if (!lead?.pm.autoPickup) return;
    const cards = this.list(projectId);
    // A PM waiting for the user's answer isn't working, so it doesn't hold up the next card.
    const working = cards.filter((c) => c.pm && (c.column === "working" || (c.column === "needs" && !c.question))).length;
    let free = MAX_PM_CASES - working - cards.filter((c) => this.pickingUp.has(c.id)).length;
    const waiting = cards.filter(
      (c) =>
        c.column === "todo" && !c.sessionId && !c.direct && !c.error && !c.modelChoice && !this.pickingUp.has(c.id) &&
        // What the PM opened itself waits for the user, unless the project lets those start too.
        (!c.openedBy || lead.pm.startOwnCases),
    );
    for (const card of waiting) {
      if (free-- <= 0) break;
      this.begin(card);
    }
  }

  /** Starts a card without waiting for it; a card that fails to start keeps the reason and waits for the user. */
  private begin(card: CardInfo): void {
    this.pickingUp.add(card.id);
    void this.move(card.id, "working")
      .catch((error: unknown) => {
        // It waits for the user to start it rather than being tried again and again.
        const stored = this.cards.get(card.id);
        if (!stored) return;
        stored.error = error instanceof Error ? error.message : String(error);
        this.changed(card.projectId);
      })
      .finally(() => {
        this.pickingUp.delete(card.id);
        this.pickUp(card.projectId);
      });
  }

  /**
   * The card in which the project's PM sets its team up. It starts at once, whether or not the PM picks cards up by
   * itself: the user asked for it just now. One at a time per project; one that couldn't start is tried again.
   */
  startSetup(projectId: string, input: { title: string; prompt: string; agent: string }): CardInfo {
    if (!this.deps.projectPM?.(projectId)) throw new KervanError("bad_message", "this project has no PM to set its team up");
    const open = this.list(projectId).find((c) => c.setup && c.column !== "done");
    if (open && (open.sessionId || this.pickingUp.has(open.id))) {
      throw new KervanError("bad_message", `the team is already being set up on the card '${open.title}'`);
    }
    if (open) {
      delete open.error;
      this.changed(projectId);
      this.begin(open);
      return open;
    }
    this.refuseProjectWork(input.agent, projectId);
    const now = new Date().toISOString();
    const card: CardInfo = {
      id: randomUUID(),
      projectId,
      title: input.title.trim().slice(0, MAX_TITLE) || "Team setup",
      prompt: input.prompt,
      agent: input.agent,
      setup: true,
      column: "todo",
      createdAt: now,
      updatedAt: now,
    };
    this.cards.set(card.id, card);
    this.changed(projectId);
    this.begin(card);
    return card;
  }

  /** Every project's waiting cards, e.g. once the server is up. */
  pickUpAll(): void {
    for (const projectId of new Set([...this.cards.values()].map((c) => c.projectId))) this.pickUp(projectId);
  }

  /** The project's cards that aren't done, in short: what a PM checks before opening one. */
  openCases(projectId: string): { id: string; title: string; column: CardColumn; kind?: CaseKind; plan?: string }[] {
    return this.list(projectId)
      .filter((c) => c.column !== "done")
      .map((c) => ({
        id: c.id,
        title: c.title,
        column: c.column,
        ...(c.openedBy ? { kind: c.openedBy.kind } : {}),
        ...(c.plan ? { plan: c.plan.length > 300 ? `${c.plan.slice(0, 299)}…` : c.plan } : {}),
      }));
  }

  /**
   * A card the PM opens itself: a feature, a security problem or a fix it found. It lands in To do as a proposal and
   * starts only when the user moves it, unless the project lets the PM's own cards start too. Limits keep a PM from
   * flooding the board or starting a chain: a card the PM opened can't open more, a session opens at most a few, the
   * project holds at most a few proposals nobody has started, and a title already open is refused.
   */
  openCase(pmSessionId: string, agent: string, input: { title: unknown; prompt: unknown; kind: unknown; reason: unknown }): CardInfo {
    const own = [...this.cards.values()].find((c) => c.sessionId === pmSessionId && c.pm);
    if (!own) throw new KervanError("bad_message", "only a card's PM can open cards");
    if (own.openedBy) throw new KervanError("bad_message", "a card the PM opened can't open more; mention what you found in your summary instead");
    const text = (value: unknown, key: string, max: number) => {
      if (typeof value !== "string" || value.trim() === "" || value.length > max) throw new KervanError("bad_message", `${key} must be 1–${max} characters`);
      return value.trim();
    };
    const title = text(input.title, "title", MAX_TITLE);
    const prompt = text(input.prompt, "prompt", MAX_PROMPT);
    const reason = text(input.reason, "reason", 2_000);
    if (!KINDS.includes(input.kind as CaseKind)) throw new KervanError("bad_message", `kind must be one of ${KINDS.join(", ")}`);
    const kind = input.kind as CaseKind;
    if (kind === "security" && !EVIDENCE.test(reason)) {
      throw new KervanError("bad_message", "a security card needs evidence: name the file (and line) in its reason");
    }
    const cards = this.list(own.projectId);
    if (cards.filter((c) => c.openedBy?.sessionId === pmSessionId).length >= MAX_CASES_PER_PM) {
      throw new KervanError("bad_message", `you've opened ${MAX_CASES_PER_PM} cards from this card already; mention the rest in your summary`);
    }
    if (cards.filter((c) => c.openedBy && c.column === "todo" && !c.sessionId).length >= MAX_PM_PROPOSALS) {
      throw new KervanError("bad_message", `${MAX_PM_PROPOSALS} cards you opened are still waiting for the user; mention this in your summary instead`);
    }
    const same = title.toLocaleLowerCase("tr");
    const duplicate = cards.find((c) => c.column !== "done" && c.title.toLocaleLowerCase("tr") === same);
    if (duplicate) throw new KervanError("bad_message", `a card titled '${duplicate.title}' is already open (${duplicate.column})`);
    const now = new Date().toISOString();
    const card: CardInfo = {
      id: randomUUID(),
      projectId: own.projectId,
      title,
      prompt,
      agent,
      openedBy: { sessionId: pmSessionId, kind, reason },
      column: "todo",
      createdAt: now,
      updatedAt: now,
    };
    this.cards.set(card.id, card);
    this.changed(card.projectId);
    this.pickUp(card.projectId);
    return card;
  }

  /** The PM asks the user something it needs to go on; the card waits in Needs you once its turn ends. */
  setQuestion(sessionId: string, question: string): CardInfo {
    const card = [...this.cards.values()].find((c) => c.sessionId === sessionId && c.pm);
    if (!card) throw new KervanError("bad_message", "this session isn't the PM of a card");
    card.question = question.trim().slice(0, MAX_PLAN);
    card.updatedAt = new Date().toISOString();
    this.changed(card.projectId);
    return card;
  }

  /** The user answered: the card's PM is no longer waiting on them. */
  clearQuestion(sessionId: string): void {
    const card = [...this.cards.values()].find((c) => c.sessionId === sessionId && c.question);
    if (!card) return;
    delete card.question;
    card.updatedAt = new Date().toISOString();
    this.changed(card.projectId);
  }

  /** The PM's plan for its card. */
  setPlan(sessionId: string, plan: string): CardInfo {
    const card = [...this.cards.values()].find((c) => c.sessionId === sessionId && c.pm);
    if (!card) throw new KervanError("bad_message", "this session isn't the PM of a card");
    card.plan = plan.trim().slice(0, MAX_PLAN);
    card.updatedAt = new Date().toISOString();
    this.changed(card.projectId);
    return card;
  }

  remove(cardId: string): void {
    const card = this.require(cardId);
    this.cards.delete(cardId);
    this.choices.get(cardId)?.cancel();
    this.changed(card.projectId);
    if (!card.sessionId) this.drop(card.files ?? []);
  }

  /** The user's answer to a card's model question. One that comes after the wait ran out has nothing left to change. */
  answerModel(cardId: string, useDefault: boolean): void {
    this.require(cardId);
    this.choices.get(cardId)?.answer(useDefault);
  }

  /** Suggests a cheaper model if the work allows it and holds the card's prompt until the user answers or the wait runs out. */
  private chooseModel(card: CardInfo, config: ConfigOption[]): Promise<ConfigChange | undefined> {
    const suggestion = suggestModel(card.title, card.prompt, config, card.split);
    if (!suggestion) return Promise.resolve(undefined);
    const waitSeconds = this.deps.modelChoiceSeconds ?? MODEL_CHOICE_SECONDS;
    card.modelChoice = { model: suggestion.name, defaultModel: suggestion.defaultName, size: suggestion.size, waitSeconds };
    this.changed(card.projectId);

    return new Promise((resolve, reject) => {
      const end = () => {
        clearTimeout(timer);
        this.choices.delete(card.id);
        delete card.modelChoice;
      };
      const answer = (useDefault: boolean) => {
        end();
        this.changed(card.projectId);
        resolve(useDefault ? undefined : { configId: suggestion.configId, value: suggestion.value });
      };
      const timer = setTimeout(() => answer(false), waitSeconds * 1000);
      timer.unref();
      this.choices.set(card.id, {
        answer,
        cancel: () => {
          end();
          reject(new Error("the card was deleted"));
        },
      });
    });
  }

  private refuseWhileChoosing(card: CardInfo): void {
    if (card.modelChoice) throw new KervanError("bad_message", "this card is waiting for its model to be chosen");
  }

  /** Called for every session update: moves the card linked to it. Done stays Done unless the session runs again. */
  follow(session: SessionInfo): void {
    for (const card of this.cards.values()) {
      if (card.sessionId !== session.id || !card.prompted) continue;
      // A PM done with its turn but waiting for the user's answer needs them, not a review.
      const next = card.question && session.status === "idle" && !session.archived ? "needs" : Board.columnFor(session, card.column);
      if (next !== card.column) {
        this.place(card, next);
        // A PM session done with its card makes room for the next one.
        if (card.pm) this.pickUp(card.projectId);
      }
    }
  }

  /** Where a started card belongs for its session's state. */
  static columnFor(session: SessionInfo, current: CardColumn): CardColumn {
    if (session.archived) return "done";
    switch (session.status) {
      case "starting":
      case "running":
        return "working";
      case "waiting":
      case "error":
        return "needs";
      default:
        // A finished turn waits for review; a card the user already put in Done stays there.
        return current === "done" ? "done" : "review";
    }
  }

  private place(card: CardInfo, column: CardColumn): void {
    card.column = column;
    card.updatedAt = new Date().toISOString();
    this.changed(card.projectId);
  }

  /** The `files` a client sent: references to files it uploaded with `stageFile`, still there. */
  private files(value: unknown): string[] {
    if (value === undefined) return [];
    if (!Array.isArray(value) || value.length > MAX_FILES || !value.every((f) => typeof f === "string" && FILE_REF.test(f))) {
      throw new KervanError("bad_message", `files must be up to ${MAX_FILES} uploaded card files`);
    }
    const missing = value.find((f) => !existsSync(join(this.filesDir, f)));
    if (missing) throw new KervanError("bad_message", `the file '${missing.slice(missing.indexOf("/") + 1)}' isn't on the server any more; add it again`);
    return [...new Set(value as string[])];
  }

  private drop(files: string[]): void {
    for (const file of files) {
      rm(join(this.filesDir, dirname(file)), { recursive: true, force: true }).catch((error) =>
        log("warn", "couldn't remove a card file", { file, error: String(error) }),
      );
    }
  }

  /** Removes uploads no card holds (the card sheet was closed without saving) once they are a day old. */
  private sweep(): void {
    const held = new Set([...this.cards.values()].flatMap((c) => (c.files ?? []).map((f) => dirname(f))));
    for (const dir of readdirSync(this.filesDir)) {
      const path = join(this.filesDir, dir);
      try {
        if (!held.has(dir) && Date.now() - statSync(path).mtimeMs > ORPHAN_MS) rmSync(path, { recursive: true, force: true });
      } catch (error) {
        log("warn", "couldn't sweep a card file", { dir, error: String(error) });
      }
    }
  }

  private require(id: string): CardInfo {
    const card = this.cards.get(id);
    if (!card) throw new KervanError("bad_message", `no card '${id}'`);
    return card;
  }

  private changed(projectId: string): void {
    this.persist();
    this.deps.broadcast({ type: "board.updated", projectId, cards: this.list(projectId) });
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    try {
      writeFileSync(temp, JSON.stringify([...this.cards.values()], null, 2));
      renameSync(temp, this.file);
    } catch (error) {
      log("error", "couldn't save the board", { error: String(error) });
    }
  }
}

/** The board for a server: started cards become sessions in their project, and every session update moves its card. */
export function attachBoard(sessions: SessionManager, file: string): Board {
  const board = new Board(file, {
    hasProject: (id) => sessions.projects?.get(id) !== undefined,
    hasAgent: (id) => sessions.agentKinds.includes(id),
    projectRefusal: (agent, projectId) => sessions.projectRefusal(agent, projectId),
    start: (card, files, choose, pm) =>
      sessions.runTask({
        agent: pm?.agent ?? card.agent,
        title: card.title,
        prompt: card.prompt,
        projectId: card.projectId,
        files,
        ...(card.split ? { split: true } : {}),
        ...(card.autoApprove ? { autoApprove: true } : {}),
        ...(pm ? { pm: { role: pm, cardId: card.id } } : {}),
        choose,
      }),
    projectPM: (projectId) => sessions.projectPM(projectId),
    session: (id) => sessions.list().find((s) => s.id === id),
    broadcast: (message) => sessions.broadcast(message),
  });
  sessions.subscribe((message) => {
    if (message.type === "session.updated") board.follow(message.session);
  });
  sessions.board = board;
  board.pickUpAll();
  return board;
}
