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

function repository(dir: string): void {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "README.md"), "# proje\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
}

async function until<T>(check: () => T | undefined | false, ms = 15_000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    const value = check();
    if (value) return value;
    if (Date.now() > end) throw new Error("timed out waiting");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

describe("setting a project's team up", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `o${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const said = (sessionId: string, kind: string) =>
    sessions.history(sessionId).filter((e) => e.kind === kind).map((e: any) => e.text).join("");

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
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("makes a PM for a project that has none and starts the setup card at once", async () => {
    const project = await sessions.projects!.save({ name: "Yeni" });
    repository(project.path);
    const result = await call({ type: "project.onboard", projectId: project.id, title: "Ekip kurulumu" });
    assert.equal(result.type, "project.onboard.result", result.message);
    const role = result.roles.find((r: any) => r.id === "pm");
    assert.deepEqual([role?.name, role?.agent, role?.lead], ["PM", "fake", true]);
    assert.deepEqual(sessions.projects!.get(project.id)!.pm, { roleId: "pm", autoPickup: true, startOwnCases: false });

    const card = await until(() => sessions.board!.list(project.id).find((c) => c.id === result.cardId && c.sessionId));
    assert.deepEqual([card.title, card.setup, card.pm], ["Ekip kurulumu", true, true]);
    const prompt = await until(() => said(card.sessionId!, "user_message") || undefined);
    assert.match(prompt, /Set up this project's team/);
    assert.match(prompt, /list_skills/);
    assert.match(prompt, /team_save/);
    assert.match(prompt, /pm_skills/);
    assert.match(prompt, /skill_draft/, "and what to do when no skill fits");
    // A project with no map gets one built alongside.
    assert.ok(sessions.projects!.get(project.id)!.map, "the map was started");

    // One setup at a time.
    assert.match((await call({ type: "project.onboard", projectId: project.id })).message, /already being set up/);
  });

  it("uses the PM a project already has, and starts even when the PM doesn't pick cards up by itself", async () => {
    const project = await sessions.projects!.save({ name: "PM'li" });
    repository(project.path);
    await call({ type: "role.save", role: { id: "lider", name: "Lider", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "lider", autoPickup: false } });
    const result = await call({ type: "project.onboard", projectId: project.id, agent: "ignored" });
    assert.equal(result.type, "project.onboard.result", result.message);
    assert.equal(result.roles.filter((r: any) => r.id.startsWith("pm")).length, 1, "no second PM role was made");
    const card = await until(() => sessions.board!.list(project.id).find((c) => c.id === result.cardId && c.sessionId));
    assert.equal(sessions.list().find((s) => s.id === card.sessionId)!.role, "Lider");
  });

  it("refuses an unknown project or agent", async () => {
    assert.match((await call({ type: "project.onboard", projectId: "yok" })).message, /no project 'yok'/);
    const project = await sessions.projects!.save({ name: "Ajansız" });
    assert.match((await call({ type: "project.onboard", projectId: project.id, agent: "nope" })).message, /no agent named 'nope'/);
    assert.equal(sessions.projects!.get(project.id)!.pm, undefined, "nothing was half made");
    assert.match((await call({ type: "project.onboard", projectId: project.id, agent: 5 })).message, /'agent' must be text/);
  });

  it("lets the PM pick its own skills, which it gets from its next card on and keeps when the app changes the PM", async () => {
    const project = await sessions.projects!.save({ name: "Skill'li" });
    repository(project.path);
    await call({ type: "role.save", role: { id: "pmx", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pmx" } });
    const ask = async (title: string, prompt: string) => {
      const saved = await call({ type: "card.save", card: { projectId: project.id, agent: "fake", title, prompt } });
      const id = saved.cards.find((c: any) => c.title === title).id;
      const sessionId = (await until(() => sessions.board!.list(project.id).find((c) => c.id === id && c.sessionId)))!.sessionId!;
      return { sessionId, text: await until(() => said(sessionId, "agent_message_chunk") || undefined) };
    };

    const picked = await ask("seç", `memcall: pm_skills {"skills":["test-yaz"]}`);
    assert.match(picked.text, /Your skills in this project: test-yaz/);
    assert.deepEqual(sessions.projects!.get(project.id)!.pm!.skills, ["test-yaz"]);
    assert.ok(sessions.history(picked.sessionId).some((e) => e.kind === "notice" && /The PM's own skills in this project: test-yaz/.test((e as any).text)));
    assert.match((await ask("yanlış", `memcall: pm_skills {"skills":["yok"]}`)).text, /refused: no skill named 'yok'/);

    const next = await ask("sonraki", "merhaba");
    assert.deepEqual(sessions.list().find((s) => s.id === next.sessionId)!.skills, ["test-yaz"]);

    // The app sends the PM without skills when it flips a switch: they stay.
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pmx", autoPickup: true } });
    assert.deepEqual(sessions.projects!.get(project.id)!.pm!.skills, ["test-yaz"]);
    // An empty list clears them.
    await ask("temizle", `memcall: pm_skills {"skills":[]}`);
    assert.equal(sessions.projects!.get(project.id)!.pm!.skills, undefined);
  });

  it("says in a card's session why it didn't go to the PM, when the project has a team or a PM", async () => {
    const project = await sessions.projects!.save({ name: "PM'siz ekip" });
    sessions.projects!.setTeam(project.id, [{ id: "dev", name: "Dev", agent: "fake", instructions: "", skills: [] }]);
    const start = async (card: object) => {
      const saved = await call({ type: "card.save", card: { projectId: project.id, agent: "fake", prompt: "merhaba", ...card } });
      const id = saved.cards.at(-1).id;
      await call({ type: "card.move", cardId: id, column: "working" });
      return (await until(() => sessions.board!.list(project.id).find((c) => c.id === id && c.sessionId)))!.sessionId!;
    };
    const notices = (id: string) => sessions.history(id).filter((e) => e.kind === "notice").map((e: any) => e.text as string);
    const orphan = await start({ title: "pm yok" });
    assert.ok(notices(orphan).some((t) => /This project has no PM, so this card went straight to Fake and its team wasn't used/.test(t)));

    await call({ type: "role.save", role: { id: "pmn", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pmn", autoPickup: false } });
    const direct = await start({ title: "doğrudan", direct: true });
    assert.ok(notices(direct).some((t) => /given straight to Fake, as chosen on it/.test(t)));
    const planned = await start({ title: "pm'li" });
    assert.ok(!notices(planned).some((t) => /straight to/.test(t)), "a PM card says nothing");
  });

  it("makes the PM hand work to a team member, not a bare agent, once the project has a team", async () => {
    const project = await sessions.projects!.save({ name: "Ekipli" });
    repository(project.path);
    await call({ type: "role.save", role: { id: "pmt", name: "PM", agent: "fake", lead: true } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pmt" } });
    const ask = async (title: string, prompt: string) => {
      const saved = await call({ type: "card.save", card: { projectId: project.id, agent: "fake", title, prompt } });
      const id = saved.cards.find((c: any) => c.title === title).id;
      const sessionId = (await until(() => sessions.board!.list(project.id).find((c) => c.id === id && c.sessionId)))!.sessionId!;
      return { sessionId, text: await until(() => said(sessionId, "agent_message_chunk") || undefined) };
    };

    // With no team yet a bare agent is fine.
    const free = await ask("boş ekip", `memcall: start_helper {"name":"Yardımcı","task":"merhaba","agent":"fake"}`);
    assert.doesNotMatch(free.text, /refused/);

    const member = await ask("üye ekle", `memcall: team_save {"id":"backend","name":"Backend Developer","agent":"fake","skills":["test-yaz"]}`);
    assert.doesNotMatch(member.text, /refused/);
    const bare = await ask("çıplak ajan", `memcall: start_helper {"name":"i18n çevirmen","task":"çevir","agent":"fake"}`);
    assert.match(bare.text, /refused: this project has a team: give role, one of 'backend' \(Backend Developer\)/);

    const handed = await ask("üyeye ver", `memcall: start_helper {"name":"API düzelt","task":"düzelt","role":"backend"}`);
    assert.doesNotMatch(handed.text, /refused/);
    const helper = await until(() => sessions.list().find((s) => s.parentId === handed.sessionId));
    assert.deepEqual([helper.role, helper.skills], ["Backend Developer", ["test-yaz"]]);
  });
});
