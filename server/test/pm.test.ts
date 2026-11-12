import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

describe("a PM's own team", () => {
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
  /** Adds a card for the PM and returns the PM's answer to it. */
  const ask = async (prompt: string, fields: object = {}) => {
    const title = `kart ${++n}`;
    const saved = await call({ type: "card.save", card: { projectId, agent: "fake", title, prompt, ...fields } });
    const id = saved.cards.find((c: any) => c.title === title).id;
    const sessionId = (await until(() => sessions.board!.list(projectId).find((c) => c.id === id && c.sessionId)))!.sessionId!;
    const text = await until(() => sessions.history(sessionId).filter((e) => e.kind === "agent_message_chunk").map((e: any) => e.text).join("") || undefined);
    return { text, sessionId };
  };

  before(async () => {
    let port: number;
    let dataDir: string;
    ({ port, sessions, stop, dataDir } = await startServer());
    mkdirSync(join(dataDir, "skills", "test-yaz"), { recursive: true });
    writeFileSync(join(dataDir, "skills", "test-yaz", "SKILL.md"), "---\nname: test-yaz\ndescription: Writes tests first.\n---\nWrite a failing test, then fix.\n");
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const project = await sessions.projects!.save({ name: "Ekip" });
    projectId = project.id;
    repository(project.path);
    await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId, pm: { roleId: "pm" } });
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("sees the skills in the library", async () => {
    assert.match((await ask("memcall: list_skills {}")).text, /- test-yaz: Writes tests first\./);
  });

  it("puts members together from agents and the skills that fit, and the user hears of it", async () => {
    const member = { id: "tester", name: "Testçi", agent: "fake", skills: ["test-yaz"], instructions: "Önce test yaz." };
    const { sessionId } = await ask(`memcall: team_save ${JSON.stringify(member)}`);
    assert.deepEqual(sessions.projects!.get(projectId)!.team, [member]);
    assert.ok(sessions.history(sessionId).some((e) => e.kind === "notice" && /Added to the project's team: Testçi \(Fake; skills: test-yaz\)/.test((e as any).text)));

    assert.match((await ask(`memcall: team_save ${JSON.stringify({ ...member, id: "x", skills: ["yok"] })}`)).text, /refused: no skill named 'yok'/);
    assert.match((await ask(`memcall: team_save ${JSON.stringify({ ...member, id: "y", agent: "nope" })}`)).text, /refused: no agent named 'nope'/);
    assert.equal(sessions.projects!.get(projectId)!.team!.length, 1, "nothing was added by the refused ones");
  });

  it("hands work to a team member, who comes with its skills and instructions", async () => {
    const { text, sessionId } = await ask(`memcall: start_helper {"name":"Test","task":"whoami","role":"tester"}`);
    assert.doesNotMatch(text, /refused/);
    const helper = await until(() => sessions.list().find((s) => s.parentId === sessionId));
    assert.deepEqual(helper.skills, ["test-yaz"]);
    assert.equal(helper.role, "Testçi");
    assert.match(JSON.stringify(sessions.helperChoices(sessionId).team), /"id":"tester"/, "list_agents shows the team");
  });

  it("is the PM's alone to change; the app can replace or empty it", async () => {
    const plain = await call({ type: "card.save", card: { projectId, agent: "fake", title: "doğrudan", prompt: "memcall: team_list {}", direct: true } });
    const id = plain.cards.find((c: any) => c.title === "doğrudan").id;
    await call({ type: "card.move", cardId: id, column: "working" });
    const sessionId = sessions.board!.list(projectId).find((c) => c.id === id)!.sessionId!;
    const text = await until(() => sessions.history(sessionId).filter((e) => e.kind === "agent_message_chunk").map((e: any) => e.text).join("") || undefined);
    assert.match(text, /refused/, "a session that isn't the PM has no team tools");

    assert.match((await call({ type: "project.team", projectId, team: [{ id: "a", name: "A", agent: "yok" }] })).message, /no agent named 'yok'/);
    const emptied = await call({ type: "project.team", projectId, team: [] });
    assert.equal(emptied.projects.find((p: any) => p.id === projectId).team, undefined);
  });
});

describe("cards the PM opens itself", () => {
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
  const board = () => sessions.board!.list(projectId);
  const replies = (sessionId: string) => sessions.history(sessionId).filter((e) => e.kind === "agent_message_chunk").map((e: any) => e.text as string);
  /** Gives a card to the PM and returns its session once the PM has answered. */
  const pmCard = async (prompt: string) => {
    const title = `kart ${++n}`;
    const saved = await call({ type: "card.save", card: { projectId, agent: "fake", title, prompt } });
    const id = saved.cards.find((c: any) => c.title === title).id;
    const sessionId = (await until(() => board().find((c) => c.id === id && c.sessionId)))!.sessionId!;
    await until(() => replies(sessionId).length > 0 && sessions.list().find((s) => s.id === sessionId)?.status === "idle");
    return sessionId;
  };
  /** Another message to a PM, and its answer. */
  const again = async (sessionId: string, text: string) => {
    const before = replies(sessionId).length;
    sessions.prompt(sessionId, text);
    await until(() => replies(sessionId).length > before && sessions.list().find((s) => s.id === sessionId)?.status === "idle");
    return replies(sessionId).at(-1)!;
  };
  const open = (fields: object) =>
    `memcall: case_open ${JSON.stringify({ prompt: "Yap.", kind: "fix", reason: "src/a.ts:3 hatalı", ...fields })}`;

  before(async () => {
    let port: number;
    ({ port, sessions, stop } = await startServer());
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const project = await sessions.projects!.save({ name: "Öneriler" });
    projectId = project.id;
    repository(project.path);
    await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId, pm: { roleId: "pm" } });
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("lands in To do as a proposal that waits for the user, and the user hears of it", async () => {
    const sessionId = await pmCard(open({ title: "Arama girdisini kaçır", kind: "security", reason: "src/search.ts:42 girdi kaçırılmadan sorguya giriyor" }));
    assert.match(replies(sessionId).at(-1)!, /Opened card/);
    const proposal = board().find((c) => c.title === "Arama girdisini kaçır")!;
    assert.deepEqual(proposal.openedBy, { sessionId, kind: "security", reason: "src/search.ts:42 girdi kaçırılmadan sorguya giriyor" });
    assert.equal(proposal.column, "todo");
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(board().find((c) => c.id === proposal.id)!.sessionId, undefined, "it doesn't start by itself");
    assert.ok(sessions.history(sessionId).some((e) => e.kind === "notice" && /Opened a card for a security problem: "Arama girdisini kaçır"\. It waits in To do/.test((e as any).text)));
    assert.match(await again(sessionId, "memcall: case_list {}"), /Arama girdisini kaçır/);
  });

  it("refuses a security card without evidence, and a title that's already open", async () => {
    const sessionId = await pmCard(open({ title: "Kanıtsız", kind: "security", reason: "bence güvensiz" }));
    assert.match(replies(sessionId).at(-1)!, /refused: a security card needs evidence/);
    assert.match(await again(sessionId, open({ title: "arama girdisini KAÇIR" })), /refused: a card titled 'Arama girdisini kaçır' is already open/);
  });

  it("doesn't let a card the PM opened open more", async () => {
    const chain = open({ title: "Zincirin sonu" });
    await pmCard(open({ title: "Zincir", prompt: chain }));
    const opened = board().find((c) => c.title === "Zincir")!;
    await call({ type: "card.move", cardId: opened.id, column: "working" });
    const sessionId = board().find((c) => c.id === opened.id)!.sessionId!;
    await until(() => replies(sessionId).length > 0);
    assert.match(replies(sessionId).at(-1)!, /refused: a card the PM opened can't open more/);
    assert.equal(board().find((c) => c.title === "Zincirin sonu"), undefined);
  });

  it("opens at most three from one card, and leaves at most five waiting in a project", async () => {
    const first = await pmCard(open({ title: "Bir" }));
    assert.match(await again(first, open({ title: "İki" })), /Opened card/);
    assert.match(await again(first, open({ title: "Üç" })), /Opened card/);
    assert.match(await again(first, open({ title: "Dört-fazla" })), /refused: you've opened 3 cards from this card already/);
    // Waiting now: the security one, Bir, İki and Üç (Zincir was started by hand); one more fills the project.
    const second = await pmCard(open({ title: "Beş" }));
    assert.match(replies(second).at(-1)!, /Opened card/);
    assert.match(await again(second, open({ title: "Altı" })), /refused: 5 cards you opened are still waiting for the user/);
  });

  it("starts what the PM opens by itself when the project allows it", async () => {
    await call({ type: "project.pm", projectId, pm: { roleId: "pm", startOwnCases: true } });
    // The five waiting proposals start now too, two at a time; the new one joins them.
    await until(() => board().filter((c) => c.openedBy && c.sessionId).length >= 2);
  });
});

describe("skills a PM suggests", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let dataDir = "";
  let n = 0;
  let projectId = "";
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const pmSays = async (prompt: string) => {
    const title = `kart ${++n}`;
    const saved = await call({ type: "card.save", card: { projectId, agent: "fake", title, prompt } });
    const id = saved.cards.find((c: any) => c.title === title).id;
    const sessionId = (await until(() => sessions.board!.list(projectId).find((c) => c.id === id && c.sessionId)))!.sessionId!;
    const text = await until(() => sessions.history(sessionId).filter((e) => e.kind === "agent_message_chunk").map((e: any) => e.text).join("") || undefined);
    return { text, sessionId };
  };
  const draft = (fields: object = {}) =>
    `memcall: skill_draft ${JSON.stringify({ name: "surum-cikar", description: "Bu depoda sürüm çıkarırken.", body: "1. Testleri çalıştır.\n2. Sürümü artır.", ...fields })}`;

  before(async () => {
    let port: number;
    ({ port, sessions, stop, dataDir } = await startServer());
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const project = await sessions.projects!.save({ name: "Skill'siz" });
    projectId = project.id;
    repository(project.path);
    await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId, pm: { roleId: "pm" } });
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("waits for the user, and no agent can use it before that", async () => {
    const { text, sessionId } = await pmSays(draft());
    assert.match(text, /Suggested\. It waits for the user/);
    const { drafts } = await call({ type: "skill.drafts" });
    assert.equal(drafts.length, 1);
    assert.equal(drafts[0].name, "surum-cikar");
    assert.equal(drafts[0].sessionId, sessionId);
    assert.ok(!existsSync(join(dataDir, "skills", "surum-cikar")), "not in the library");
    assert.ok(sessions.history(sessionId).some((e) => e.kind === "notice" && /No agent uses it until you accept it/.test((e as any).text)));
    // Not a skill a role or member can be given yet.
    assert.match((await call({ type: "role.save", role: { id: "r", name: "R", agent: "fake", skills: ["surum-cikar"] } })).message, /no skill named 'surum-cikar'/);
  });

  it("becomes a skill in the library once accepted, and is gone when discarded", async () => {
    const { drafts } = await call({ type: "skill.drafts" });
    const accepted = await call({ type: "skill.draft.accept", draftId: drafts[0].id });
    assert.deepEqual(accepted.drafts, []);
    const skill = readFileSync(join(dataDir, "skills", "surum-cikar", "SKILL.md"), "utf8");
    assert.match(skill, /^---\nname: surum-cikar\ndescription: Bu depoda sürüm çıkarırken\.\n---\n\n1\. Testleri çalıştır\./);
    assert.equal((await call({ type: "role.save", role: { id: "r", name: "R", agent: "fake", skills: ["surum-cikar"] } })).type, "role.list.result");

    assert.match((await pmSays(draft())).text, /refused: the library already has a skill named 'surum-cikar'/);
    await pmSays(draft({ name: "baska" }));
    const waiting = (await call({ type: "skill.drafts" })).drafts;
    await call({ type: "skill.draft.discard", draftId: waiting[0].id });
    assert.deepEqual((await call({ type: "skill.drafts" })).drafts, []);
    assert.ok(!existsSync(join(dataDir, "skills", "baska")));
  });
});
