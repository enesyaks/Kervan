import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import WebSocket from "ws";
import { isDue, localParts } from "../src/schedules.ts";
import { parseLsof, parseSs } from "../src/tunnel.ts";
import type { ScheduleInfo } from "../src/protocol.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer, TEST_TOKEN } from "./helpers.ts";

describe("changes, projects, schedules, terminals, ports, usage", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  const sockets: WebSocket[] = [];
  let counter = 0;
  const nextId = () => `f${++counter}`;

  async function client(): Promise<{ ws: WebSocket; inbox: Inbox }> {
    const ws = openSocket(port);
    sockets.push(ws);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    return { ws, inbox };
  }

  /** Sends a request and resolves with its answer (or the error carrying its id). */
  async function ask(ws: WebSocket, inbox: Inbox, message: Record<string, unknown>): Promise<any> {
    const id = nextId();
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id, 15_000);
  }

  async function idleSession(ws: WebSocket, inbox: Inbox, extra: Record<string, unknown> = {}): Promise<string> {
    const created = await ask(ws, inbox, { type: "session.create", agent: "fake", ...extra });
    assert.equal(created.type, "session.created", JSON.stringify(created));
    const sessionId = created.session.id;
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");
    return sessionId;
  }

  /** Sends a message and waits for the turn to end; returns what the agent answered. */
  async function turn(ws: WebSocket, inbox: Inbox, sessionId: string, text: string, attachments?: string[]): Promise<string> {
    const start = inbox.received.length;
    const ok = await ask(ws, inbox, { type: "session.prompt", sessionId, text, ...(attachments ? { attachments } : {}) });
    assert.equal(ok.type, "ok", JSON.stringify(ok));
    const mine = (m: any) => m.type === "session.event" && m.sessionId === sessionId && inbox.received.indexOf(m) >= start;
    await inbox.waitFor((m) => mine(m) && m.event.kind === "turn_end", 10_000);
    return inbox.received
      .filter((m) => mine(m) && m.event.kind === "agent_message_chunk")
      .map((m) => m.event.text)
      .join("");
  }

  const events = (inbox: Inbox, sessionId: string, kind: string) =>
    inbox.received.filter((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === kind).map((m) => m.event);

  before(async () => {
    ({ port, stop, sessions } = await startServer());
  });

  after(async () => {
    for (const ws of sockets) ws.terminate();
    await stop();
  });

  it("forwards the agent's edits as diffs, its plan and its slash commands", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "commands");
    assert.deepEqual(events(inbox, sessionId, "commands")[0].commands, [
      { name: "review", description: "Review the changes" },
      { name: "explain", description: "Explain code", hint: "file or symbol" },
    ]);

    assert.equal(await turn(ws, inbox, sessionId, "write notes.md hello"), "wrote notes.md");
    const [tool] = events(inbox, sessionId, "tool_call");
    assert.deepEqual(tool.diffs, [{ path: "notes.md", newText: "hello" }]);
    assert.deepEqual(events(inbox, sessionId, "plan")[0].entries.map((e: any) => e.status), ["completed", "in_progress"]);
  });

  it("shows what changed since the first message and the last one, and rewinds", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    await turn(ws, inbox, sessionId, "write a.txt one");
    await turn(ws, inbox, sessionId, "write a.txt two");
    await turn(ws, inbox, sessionId, "write b.txt bee");

    const all = (await ask(ws, inbox, { type: "session.changes", sessionId })).changes;
    assert.deepEqual(all.files.map((f: any) => [f.path, f.status]), [["a.txt", "added"], ["b.txt", "added"]]);
    assert.equal(all.repository, false);
    assert.match(all.patch, /\+two/);

    const last = (await ask(ws, inbox, { type: "session.changes", sessionId, since: "turn" })).changes;
    assert.deepEqual(last.files.map((f: any) => f.path), ["b.txt"]);

    // Back to before the second message: a.txt says "one" again and b.txt is gone.
    const [, second] = events(inbox, sessionId, "checkpoint");
    assert.equal((await ask(ws, inbox, { type: "session.revert", sessionId, seq: second.messageSeq })).type, "ok");
    const folder = sessions.workspace(sessionId);
    assert.equal(readFileSync(join(folder, "a.txt"), "utf8"), "one");
    assert.equal(existsSync(join(folder, "b.txt")), false);
    assert.ok(events(inbox, sessionId, "notice").some((n) => /Files rewound to before/.test(n.text)));
    // The agent hears about it with the next message.
    assert.match(await turn(ws, inbox, sessionId, "prefacecheck"), /rewound the folder/);
  });

  it("puts back a single file", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    const folder = sessions.workspace(sessionId);
    writeFileSync(join(folder, "keep.txt"), "original");
    await turn(ws, inbox, sessionId, "write keep.txt changed");
    await turn(ws, inbox, sessionId, "write other.txt new");
    const [first] = events(inbox, sessionId, "checkpoint");
    const answer = await ask(ws, inbox, { type: "session.revert", sessionId, seq: first.messageSeq, paths: ["keep.txt"] });
    assert.equal(answer.type, "ok", JSON.stringify(answer));
    assert.equal(readFileSync(join(folder, "keep.txt"), "utf8"), "original");
    assert.equal(readFileSync(join(folder, "other.txt"), "utf8"), "new");

    const outside = await ask(ws, inbox, { type: "session.revert", sessionId, seq: first.messageSeq, paths: ["../x"] });
    assert.equal(outside.type, "error");
  });

  it("works in a project's folder with its instructions, and commits to its repository", async () => {
    const { ws, inbox } = await client();
    const repo = mkdtempSync(join(tmpdir(), "kervan-project-"));
    execFileSync("git", ["init", "-q", repo]);
    const saved = await ask(ws, inbox, {
      type: "project.save",
      project: { name: "Web sitesi", path: repo, instructions: "Use tabs, never spaces." },
    });
    assert.equal(saved.type, "project.list.result", JSON.stringify(saved));
    const project = saved.projects.find((p: any) => p.name === "Web sitesi");
    assert.equal(project.path, repo);

    const sessionId = await idleSession(ws, inbox, { projectId: project.id });
    assert.equal(sessions.workspace(sessionId), repo);
    assert.match(await turn(ws, inbox, sessionId, "prefacecheck"), /Use tabs, never spaces\./);

    await turn(ws, inbox, sessionId, "write index.html <h1>Merhaba</h1>");
    const changes = (await ask(ws, inbox, { type: "session.changes", sessionId })).changes;
    assert.equal(changes.repository, true);
    assert.equal((await ask(ws, inbox, { type: "session.commit", sessionId, message: "Ana sayfa" })).type, "ok");
    assert.match(execFileSync("git", ["-C", repo, "log", "--format=%s"]).toString(), /Ana sayfa/);
    // Kervan's checkpoints stay out of the project's history.
    assert.equal(execFileSync("git", ["-C", repo, "rev-list", "--count", "HEAD"]).toString().trim(), "1");
    assert.equal((await ask(ws, inbox, { type: "session.commit", sessionId, message: "Boş" })).type, "error");

    const fresh = await ask(ws, inbox, { type: "project.save", project: { name: "Boş proje" } });
    assert.ok(existsSync(fresh.projects.find((p: any) => p.name === "Boş proje").path));
    assert.equal((await ask(ws, inbox, { type: "project.save", project: { name: "x", path: "relative/path" } })).type, "error");
    assert.equal((await ask(ws, inbox, { type: "project.save", project: { name: "x", gitUrl: "file:///etc" } })).type, "error");
    assert.equal((await ask(ws, inbox, { type: "session.create", agent: "fake", projectId: "nope" })).type, "error");
  });

  it("sends pictures as images to agents that see them", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    writeFileSync(join(sessions.workspace(sessionId), "shot.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    assert.equal(await turn(ws, inbox, sessionId, "imagecheck", ["shot.png"]), "images: image/png");
  });

  it("keeps a log of spending by day and agent", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    await turn(ws, inbox, sessionId, "usage 0.25");
    await turn(ws, inbox, sessionId, "usage 0.75");
    const { report } = await ask(ws, inbox, { type: "usage.report", days: 7, timeZone: "Europe/Istanbul" });
    const today = localParts(new Date(), "Europe/Istanbul").date;
    assert.ok(report.days.some((d: any) => d.date === today && d.agent === "fake" && d.costUsd >= 0.75), JSON.stringify(report));
    assert.equal(report.sessions.find((s: any) => s.sessionId === sessionId).costUsd, 0.75);
    assert.equal((await ask(ws, inbox, { type: "usage.report", days: 7, timeZone: "Mars/Olympus" })).type, "error");
  });

  it("runs a scheduled task in a new session", async () => {
    const { ws, inbox } = await client();
    const saved = await ask(ws, inbox, {
      type: "schedule.save",
      schedule: {
        title: "Sabah kontrolü",
        agent: "fake",
        prompt: "günaydın",
        when: { kind: "daily", time: "09:00", weekdays: [1, 2, 3, 4, 5] },
        timeZone: "Europe/Istanbul",
      },
    });
    assert.equal(saved.type, "schedule.list.result", JSON.stringify(saved));
    const [schedule] = saved.schedules;
    const ran = await ask(ws, inbox, { type: "schedule.run", scheduleId: schedule.id });
    const sessionId = ran.schedules[0].lastSessionId;
    assert.ok(sessionId, JSON.stringify(ran));
    await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk" && m.event.text === "günaydın",
    );
    assert.equal(sessions.list().find((s) => s.id === sessionId)?.scheduleId, schedule.id);

    for (const bad of [
      { title: "x", agent: "fake", prompt: "p", when: { kind: "interval", minutes: 1 }, timeZone: "UTC" },
      { title: "x", agent: "nope", prompt: "p", when: { kind: "interval", minutes: 30 }, timeZone: "UTC" },
      { title: "x", agent: "fake", prompt: "p", when: { kind: "daily", time: "25:00", weekdays: [1] }, timeZone: "UTC" },
      { title: "x", agent: "fake", prompt: "p", when: { kind: "interval", minutes: 30 }, timeZone: "Mars/Olympus" },
    ]) {
      assert.equal((await ask(ws, inbox, { type: "schedule.save", schedule: bad })).type, "error");
    }
    assert.equal((await ask(ws, inbox, { type: "schedule.delete", scheduleId: schedule.id })).schedules.length, 0);
  });

  it("decides when a schedule is due", () => {
    const base: ScheduleInfo = {
      id: "s",
      title: "t",
      agent: "fake",
      prompt: "p",
      when: { kind: "daily", time: "09:00", weekdays: [1, 2, 3, 4, 5] },
      timeZone: "Europe/Istanbul",
      enabled: true,
      createdAt: "2026-10-01T00:00:00Z",
    };
    // Monday 2026-10-26; Istanbul is UTC+3.
    assert.equal(isDue(base, new Date("2026-10-26T05:59:00Z")), false);
    assert.equal(isDue(base, new Date("2026-10-26T06:00:00Z")), true);
    assert.equal(isDue({ ...base, lastRunAt: "2026-10-26T06:00:10Z" }, new Date("2026-10-26T07:00:00Z")), false);
    assert.equal(isDue({ ...base, lastRunAt: "2026-10-26T06:00:10Z" }, new Date("2026-10-27T06:01:00Z")), true);
    // Saturday.
    assert.equal(isDue(base, new Date("2026-10-31T06:00:00Z")), false);
    // Saved after today's time: not until tomorrow.
    assert.equal(isDue({ ...base, createdAt: "2026-10-26T07:00:00Z" }, new Date("2026-10-26T08:00:00Z")), false);
    assert.equal(isDue({ ...base, enabled: false }, new Date("2026-10-26T06:00:00Z")), false);

    const every = { ...base, when: { kind: "interval" as const, minutes: 30 } };
    assert.equal(isDue(every, new Date("2026-10-01T00:29:00Z")), false);
    assert.equal(isDue(every, new Date("2026-10-01T00:30:00Z")), true);
    assert.equal(isDue({ ...every, lastRunAt: "2026-10-01T00:30:00Z" }, new Date("2026-10-01T00:45:00Z")), false);
  });

  it("opens a shell in the session's folder", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    const shell = await ask(ws, inbox, { type: "terminal.open", sessionId });
    assert.equal(shell.type, "terminal.opened", JSON.stringify(shell));
    const printed = () =>
      inbox.received.filter((m) => m.type === "terminal.output" && m.terminalId === shell.terminalId).map((m) => m.data).join("");
    await ask(ws, inbox, { type: "terminal.input", terminalId: shell.terminalId, data: "echo kervan-$((40+2))\n" });
    await inbox.waitFor(() => printed().includes("kervan-42"), 10_000);
    // Opening again finds the same shell with what it printed so far.
    const again = await ask(ws, inbox, { type: "terminal.open", sessionId });
    assert.equal(again.terminalId, shell.terminalId);
    assert.match(again.backlog, /kervan-42/);
    await ask(ws, inbox, { type: "terminal.close", terminalId: shell.terminalId });
    await inbox.waitFor((m) => m.type === "terminal.exited" && m.terminalId === shell.terminalId, 10_000);
  });

  it("forwards a connection to a port on the server", async () => {
    const echo = createServer((socket) => socket.on("data", (data) => socket.write(`echo:${data}`)));
    await new Promise<void>((resolve) => echo.listen(0, "127.0.0.1", resolve));
    const target = (echo.address() as AddressInfo).port;
    try {
      const tunnel = new WebSocket(`ws://127.0.0.1:${port}/v1/tunnel?port=${target}`, { headers: { authorization: `Bearer ${TEST_TOKEN}` } });
      await opened(tunnel);
      const reply = new Promise<string>((resolve) => tunnel.once("message", (data) => resolve(data.toString())));
      tunnel.send(Buffer.from("merhaba"));
      assert.equal(await reply, "echo:merhaba");
      tunnel.close();

      const refused = new WebSocket(`ws://127.0.0.1:${port}/v1/tunnel?port=${target}`);
      const status = await new Promise<number>((resolve) => refused.once("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0)));
      assert.equal(status, 401);
    } finally {
      echo.close();
    }
  });

  it("reads listening ports from ss and lsof", () => {
    assert.deepEqual(
      parseSs('LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=12,fd=20))\nLISTEN 0 4096 [::]:5173 [::]:*\n'),
      [{ port: 3000, process: "node" }, { port: 5173 }],
    );
    assert.deepEqual(
      parseLsof("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 123 me 20u IPv4 0x1 0t0 TCP *:8080 (LISTEN)\n"),
      [{ port: 8080, process: "node" }],
    );
  });
});
