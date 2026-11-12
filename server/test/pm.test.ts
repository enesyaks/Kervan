import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" }).trim();

/** A repository with one commit on main. */
function repository(dir: string): void {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "README.md"), "# proje\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
}

describe("a project's PM", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };

  before(async () => {
    let port: number;
    ({ port, sessions, stop } = await startServer());
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("is a role, given to a project and taken away with project.pm", async () => {
    const project = await sessions.projects!.save({ name: "PM'li" });
    repository(project.path);
    assert.equal((await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true } })).type, "role.list.result");

    const set = await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pm" } });
    assert.equal(set.type, "project.list.result", set.message);
    // Picking new cards up by itself is on unless asked otherwise; starting its own cards is off.
    assert.deepEqual(set.projects.find((p: any) => p.id === project.id).pm, { roleId: "pm", autoPickup: true, startOwnCases: false });
    assert.equal(sessions.projectPM(project.id)?.role.agent, "fake");

    assert.match((await call({ type: "project.pm", projectId: project.id, pm: { roleId: "yok" } })).message, /no role named 'yok'/);
    assert.match((await call({ type: "project.pm", projectId: "nope", pm: { roleId: "pm" } })).message, /no project 'nope'/);

    const removed = await call({ type: "project.pm", projectId: project.id, pm: null });
    assert.equal(removed.projects.find((p: any) => p.id === project.id).pm, undefined);
  });

  it("stops counting as a PM once its role is deleted", async () => {
    const project = await sessions.projects!.save({ name: "Rolü silinen" });
    repository(project.path);
    await call({ type: "role.save", role: { id: "gecici", name: "Geçici PM", agent: "fake" } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "gecici", autoPickup: false } });
    assert.ok(sessions.projectPM(project.id));
    await call({ type: "role.delete", roleId: "gecici" });
    assert.equal(sessions.projectPM(project.id), undefined);
  });
});

/** Waits until `check` returns something truthy, or fails after `ms`. */
async function until<T>(check: () => T | undefined | false, ms = 15_000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    const value = check();
    if (value) return value;
    if (Date.now() > end) throw new Error("timed out waiting");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

describe("cards in a project with a PM", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  let projectId = "";
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const card = (fields: object) => call({ type: "card.save", card: { projectId, agent: "fake", ...fields } });
  const board = () => sessions.board!.list(projectId);
  const info = (id: string) => sessions.list().find((s) => s.id === id);

  before(async () => {
    let port: number;
    ({ port, sessions, stop } = await startServer());
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const project = await sessions.projects!.save({ name: "Kartlar", instructions: "Türkçe yaz." });
    projectId = project.id;
    repository(project.path);
    await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true, instructions: "Kısa planlar yaz." } });
    await call({ type: "project.pm", projectId, pm: { roleId: "pm" } });
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("starts the PM as soon as a card is added, and the PM writes its plan on the card", async () => {
    const saved = await card({ title: "Plan", prompt: `memcall: case_plan {"plan":"1. Testleri yaz\\n2. Düzelt"}` });
    const id = saved.cards.find((c: any) => c.title === "Plan").id;
    const started = await until(() => board().find((c) => c.id === id && c.plan));
    assert.equal(started.plan, "1. Testleri yaz\n2. Düzelt");
    assert.equal(started.pm, true);
    const session = info(started.sessionId!)!;
    assert.equal(session.pmCard, id);
    assert.equal(session.role, "PM");
    assert.equal(session.orchestrate, true, "a PM hands work out");
    assert.equal(session.projectId, projectId);
  });

  it("tells the PM its job, and with no skills to plan from the project itself", async () => {
    const saved = await card({ title: "Önbilgi", prompt: "prefacecheck" });
    const id = saved.cards.find((c: any) => c.title === "Önbilgi").id;
    const sessionId = (await until(() => board().find((c) => c.id === id && c.sessionId)))!.sessionId!;
    const reply = await until(() => {
      const text = sessions.history(sessionId).filter((e) => e.kind === "agent_message_chunk").map((e: any) => e.text).join("");
      return text || undefined;
    });
    assert.match(reply, /You are the PM of project "Kartlar"/);
    assert.match(reply, /You have no skills\. Plan from what the project itself says/);
    assert.match(reply, /case_plan/);
    assert.match(reply, /Kısa planlar yaz\./, "its role's own instructions too");
    assert.match(reply, /Türkçe yaz\./, "and the project's");
  });

  it("works on at most two cards at once; the rest wait their turn in To do", async () => {
    // Each asks a question nobody answers yet, so its PM keeps working.
    const ids: string[] = [];
    for (const title of ["Bir", "İki", "Üç"]) {
      const saved = await card({ title, prompt: "askperm: edit dosya" });
      ids.push(saved.cards.find((c: any) => c.title === title).id);
    }
    await until(() => ids.filter((id) => board().find((c) => c.id === id)?.column === "needs").length === 2);
    const third = board().find((c) => c.id === ids[2])!;
    assert.equal(third.column, "todo");
    assert.equal(third.sessionId, undefined);

    // Answering one lets its turn end, which makes room for the third.
    const first = board().find((c) => c.id === ids[0])!;
    const request = sessions.history(first.sessionId!).find((e) => e.kind === "permission_request") as any;
    sessions.respond(first.sessionId!, request.requestId, request.options[0].optionId);
    await until(() => board().find((c) => c.id === ids[2])?.sessionId);
    for (const id of ids.slice(1)) {
      const waiting = board().find((c) => c.id === id)!;
      const ask = sessions.history(waiting.sessionId!).find((e) => e.kind === "permission_request") as any;
      if (ask) await until(() => info(waiting.sessionId!)?.status === "waiting");
      if (ask) sessions.respond(waiting.sessionId!, ask.requestId, ask.options[0].optionId);
    }
  });

  it("leaves a card meant for its own agent to that agent, when it's moved to Working", async () => {
    const saved = await card({ title: "Doğrudan", prompt: "whoami", direct: true });
    const id = saved.cards.find((c: any) => c.title === "Doğrudan").id;
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(board().find((c) => c.id === id)!.sessionId, undefined, "the PM doesn't pick it up");
    assert.equal((await call({ type: "card.move", cardId: id, column: "working" })).type, "ok");
    const started = board().find((c) => c.id === id)!;
    assert.equal(started.pm, undefined);
    assert.equal(info(started.sessionId!)?.pmCard, undefined);
  });

  it("waits to be moved to Working when the PM doesn't pick cards up by itself", async () => {
    await call({ type: "project.pm", projectId, pm: { roleId: "pm", autoPickup: false } });
    const saved = await card({ title: "Elle", prompt: "whoami" });
    const id = saved.cards.find((c: any) => c.title === "Elle").id;
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(board().find((c) => c.id === id)!.sessionId, undefined);
    await call({ type: "card.move", cardId: id, column: "working" });
    assert.equal(info(board().find((c) => c.id === id)!.sessionId!)?.pmCard, id, "still the PM's when started by hand");
  });
});
