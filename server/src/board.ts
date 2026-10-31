import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { log } from "./log.ts";
import { KervanError, type CardColumn, type CardInfo, type ServerMessage, type SessionInfo } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";

const COLUMNS: readonly CardColumn[] = ["todo", "working", "needs", "review", "done"];
const MAX_TITLE = 120;
const MAX_PROMPT = 20_000;

export interface BoardDeps {
  hasProject: (id: string) => boolean;
  hasAgent: (id: string) => boolean;
  /** Starts a session in the project with the card's prompt; resolves with its id once the prompt is sent. */
  start: (card: CardInfo) => Promise<string>;
  /** The session as it is now, to catch up after starting. */
  session: (id: string) => SessionInfo | undefined;
  broadcast: (message: ServerMessage) => void;
}

/**
 * A task board per project. A card is a title and a prompt; moving it to Working starts a session with the prompt,
 * and from then on the card follows its session: waiting for approval → Needs you, a finished turn → Review,
 * archived → Done. Cards live on the server, so every client sees the same board.
 */
export class Board {
  private readonly file: string;
  private readonly deps: BoardDeps;
  private cards: Map<string, CardInfo>;

  constructor(file: string, deps: BoardDeps) {
    this.file = file;
    this.deps = deps;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as CardInfo[]) : [];
    this.cards = new Map(stored.map((card) => [card.id, card]));
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
    const now = new Date().toISOString();

    if (typeof input.id === "string") {
      const card = this.require(input.id);
      if (card.sessionId) throw new KervanError("bad_message", "a card can't be changed once its session has started");
      Object.assign(card, { title, prompt, agent, updatedAt: now });
      this.changed(card.projectId);
      return card;
    }
    const projectId = text("projectId", 80);
    if (!this.deps.hasProject(projectId)) throw new KervanError("bad_message", `no project '${projectId}'`);
    const card: CardInfo = { id: randomUUID(), projectId, title, prompt, agent, column: "todo", createdAt: now, updatedAt: now };
    this.cards.set(card.id, card);
    this.changed(projectId);
    return card;
  }

  /** Moving a card that hasn't started to Working starts its session; other moves just put it there. */
  async move(cardId: string, column: string): Promise<void> {
    if (!COLUMNS.includes(column as CardColumn)) throw new KervanError("bad_message", `column must be one of ${COLUMNS.join(", ")}`);
    const card = this.require(cardId);
    if (column === "working" && !card.sessionId) {
      this.place(card, "working");
      try {
        card.sessionId = await this.deps.start(card);
        card.prompted = true;
      } catch (error) {
        this.place(card, "todo");
        throw new KervanError("bad_message", `couldn't start the session: ${error instanceof Error ? error.message : String(error)}`);
      }
      // The turn may already have moved on while the session started.
      const session = this.deps.session(card.sessionId);
      if (session) this.follow(session);
      this.changed(card.projectId);
      return;
    }
    if (column === "todo" && card.sessionId) throw new KervanError("bad_message", "a card whose session has started can't go back to To do");
    this.place(card, column as CardColumn);
  }

  remove(cardId: string): void {
    const card = this.require(cardId);
    this.cards.delete(cardId);
    this.changed(card.projectId);
  }

  /** Called for every session update: moves the card linked to it. Done stays Done unless the session runs again. */
  follow(session: SessionInfo): void {
    for (const card of this.cards.values()) {
      if (card.sessionId !== session.id || !card.prompted) continue;
      const next = Board.columnFor(session, card.column);
      if (next !== card.column) this.place(card, next);
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
    start: (card) => sessions.runTask({ agent: card.agent, title: card.title, prompt: card.prompt, projectId: card.projectId }),
    session: (id) => sessions.list().find((s) => s.id === id),
    broadcast: (message) => sessions.broadcast(message),
  });
  sessions.subscribe((message) => {
    if (message.type === "session.updated") board.follow(message.session);
  });
  sessions.board = board;
  return board;
}
