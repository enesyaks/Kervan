import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type AddressInfo } from "node:net";
import { createServer as createHttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import WebSocket from "ws";
import { isDue, localParts } from "../src/schedules.ts";
import { parseLsof, parseSs } from "../src/tunnel.ts";
import { redact } from "../src/diagnostics.ts";
import { githubRepoURL, openPullRequest } from "../src/pullrequest.ts";
import { accountFrom, deviceCodeFrom, GitHubAccess } from "../src/github.ts";
import { AgentLogin, loginPromptFrom } from "../src/agentlogin.ts";
import { Board } from "../src/board.ts";
import { WebAccess as WebAccessStore, type WebAccess } from "../src/webaccess.ts";
import { log } from "../src/log.ts";
import type { ScheduleInfo } from "../src/protocol.ts";
import type { SessionManager } from "../src/sessions.ts";
import { VERSION } from "../src/version.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer, TEST_TOKEN } from "./helpers.ts";

describe("changes, projects, schedules, terminals, ports, usage", () => {
  let port = 0;
  let sessions: SessionManager;
  let dataDir = "";
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
    ({ port, stop, sessions, dataDir } = await startServer());
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

  it("has another agent review a session's changes on a copy it can't harm", async () => {
    const { ws, inbox } = await client();
    const idle = await idleSession(ws, inbox);
    const refused = await ask(ws, inbox, { type: "session.review", sessionId: idle, agent: "fake" });
    assert.equal(refused.type, "error");
    assert.match(refused.message, /nothing to review/);

    const authorId = await idleSession(ws, inbox);
    await turn(ws, inbox, authorId, "write page.html hello world");
    assert.equal((await ask(ws, inbox, { type: "session.review", sessionId: authorId, agent: "fake" })).type, "ok");
    const reviewer = sessions.list().find((s) => s.reviewOf === authorId)!;
    assert.ok(reviewer, "the review is a session of its own, linked to the one it reviews");
    const [authorDir, reviewDir] = [sessions.workspace(authorId), sessions.workspace(reviewer.id)];
    assert.notEqual(reviewDir, authorDir);
    assert.match(readFileSync(join(reviewDir, "CHANGES.diff"), "utf8"), /page\.html/);
    assert.equal(readFileSync(join(reviewDir, "page.html"), "utf8").trim(), "hello world");
    const history = await ask(ws, inbox, { type: "session.history", sessionId: reviewer.id });
    const reviewPrompt = history.events.find((e: any) => e.kind === "user_message").text;
    assert.match(reviewPrompt, /Review the work.*most severe first/s);
    assert.match(reviewPrompt, /What the user asked for[^]*write page\.html hello world/, "the reviewer sees the request, not just the title");

    // Whatever the reviewer writes stays in its copy.
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === reviewer.id && m.event.kind === "turn_end");
    await turn(ws, inbox, reviewer.id, "write page.html broken by the reviewer");
    assert.equal(readFileSync(join(authorDir, "page.html"), "utf8").trim(), "hello world");
  });

  it("alerts once per approval with the session's name only, and never holds a session up", async () => {
    const { ws, inbox } = await client();
    // A stand-in ntfy server that remembers what it was sent.
    const received: { body: any; auth: string | undefined }[] = [];
    const ntfy = createHttpServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => (body += chunk));
      req.on("end", () => {
        received.push({ body: JSON.parse(body), auth: req.headers.authorization });
        res.end("{}");
      });
    });
    await new Promise<void>((resolve) => ntfy.listen(0, "127.0.0.1", resolve));
    const ntfyUrl = `http://127.0.0.1:${(ntfy.address() as AddressInfo).port}`;
    try {
      const initial = (await ask(ws, inbox, { type: "alerts.get" })).alerts;
      assert.equal(initial.enabled, false);
      assert.equal(initial.includeNames, false, "session names, often prompt text, are left out until turned on");
      const saved = await ask(ws, inbox, {
        type: "alerts.save",
        alerts: {
          enabled: true,
          events: { finished: false },
          ntfy: { server: ntfyUrl, topic: "kervan-test", token: "t0k3n" },
          openUrl: "http://kervan:7420",
          includeNames: true,
        },
      });
      assert.equal(saved.type, "alerts.result", JSON.stringify(saved));
      assert.equal(saved.alerts.ntfy.tokenSet, true);
      assert.ok(!JSON.stringify(saved).includes("t0k3n"), "the token never goes back to a client");

      const sessionId = await idleSession(ws, inbox);
      await ask(ws, inbox, { type: "session.rename", sessionId, title: "Docs" });
      send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "use the tool on SECRETWORD" });
      const request = await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_request");
      const started = Date.now();
      while (received.length === 0 && Date.now() - started < 5_000) await new Promise((r) => setTimeout(r, 50));
      assert.equal(received.length, 1, "one alert within five seconds");
      const alert = received[0];
      assert.equal(alert.body.topic, "kervan-test");
      assert.equal(alert.body.title, "Docs");
      assert.match(alert.body.message, /waiting for your approval/);
      assert.equal(alert.body.click, `http://kervan:7420/#/s/${sessionId}`);
      assert.equal(alert.auth, "Bearer t0k3n");
      assert.ok(!JSON.stringify(alert.body).includes("SECRETWORD"), "no prompt text in the alert");

      // Resolving it sends nothing more (finished-turn alerts are off here).
      await ask(ws, inbox, { type: "session.permission", sessionId, requestId: request.event.requestId, optionId: "yes" });
      await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");
      await new Promise((r) => setTimeout(r, 300));
      assert.equal(received.length, 1);
      assert.equal((await ask(ws, inbox, { type: "alerts.test" })).type, "ok");
      assert.equal(received.length, 2);

      // Without names, an alert says only which agent and what happened.
      await ask(ws, inbox, { type: "alerts.save", alerts: { includeNames: false } });
      send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "use the tool once more" });
      const nameless = await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_request" && m.event.requestId !== request.event.requestId);
      while (received.length < 3) await new Promise((r) => setTimeout(r, 50));
      assert.equal(received[2].body.title, "Kervan");
      assert.match(received[2].body.message, /^Fake/);
      await ask(ws, inbox, { type: "session.permission", sessionId, requestId: nameless.event.requestId, optionId: "yes" });
      await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end" && m.event.seq > nameless.event.seq);

      // An address nothing answers on: the turn still ends at once, and the test says why it failed.
      await ask(ws, inbox, { type: "alerts.save", alerts: { events: { finished: true }, ntfy: { server: "http://127.0.0.1:1", topic: "kervan-test", token: null } } });
      const before = Date.now();
      send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "use the tool again" });
      const second = await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_request" && m.event.requestId !== request.event.requestId && m.event.requestId !== nameless.event.requestId);
      await ask(ws, inbox, { type: "session.permission", sessionId, requestId: second.event.requestId, optionId: "yes" });
      await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end" && m.event.seq > second.event.seq);
      assert.ok(Date.now() - before < 3_000, "alerts that fail to send don't slow the session");
      const failed = await ask(ws, inbox, { type: "alerts.test" });
      assert.equal(failed.type, "error");
      assert.match(failed.message, /couldn't be reached/);
    } finally {
      ntfy.close();
      await ask(ws, inbox, { type: "alerts.save", alerts: { enabled: false } });
    }
  });

  it("runs a board card as a session and moves the card with it, and keeps the board across a restart", async () => {
    const { ws, inbox } = await client();
    const made = await ask(ws, inbox, { type: "project.save", project: { name: "Pano" } });
    const project = made.projects.find((p: any) => p.name === "Pano");
    const prompt = "use the tool on the readme";
    const saved = await ask(ws, inbox, { type: "card.save", card: { projectId: project.id, title: "README", prompt, agent: "fake" } });
    assert.equal(saved.type, "board.result", JSON.stringify(saved));
    const card = saved.cards[0];
    assert.equal(card.column, "todo");
    assert.equal((await ask(ws, inbox, { type: "card.save", card: { projectId: project.id, title: "x", prompt: "y", agent: "nobody" } })).type, "error");

    // Working starts a session with the card's prompt; the approval it asks for puts the card in Needs you.
    assert.equal((await ask(ws, inbox, { type: "card.move", cardId: card.id, column: "working" })).type, "ok");
    const needs = await inbox.waitFor((m) => m.type === "board.updated" && m.cards.some((c: any) => c.id === card.id && c.column === "needs"));
    const sessionId = needs.cards.find((c: any) => c.id === card.id).sessionId;
    assert.ok(sessionId);
    const history = await ask(ws, inbox, { type: "session.history", sessionId });
    assert.equal(history.events.find((e: any) => e.kind === "user_message").text, prompt);

    // Answering it finishes the turn: Review.
    const request = await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_request");
    await ask(ws, inbox, { type: "session.permission", sessionId, requestId: request.event.requestId, optionId: "yes" });
    await inbox.waitFor((m) => m.type === "board.updated" && m.cards.some((c: any) => c.id === card.id && c.column === "review"));
    // A started card keeps its wording and can't go back to To do.
    assert.equal((await ask(ws, inbox, { type: "card.save", card: { id: card.id, title: "z", prompt: "z", agent: "fake" } })).type, "error");
    assert.equal((await ask(ws, inbox, { type: "card.move", cardId: card.id, column: "todo" })).type, "error");

    // Archiving the session puts the card in Done.
    await ask(ws, inbox, { type: "session.archive", sessionId, archived: true });
    await inbox.waitFor((m) => m.type === "board.updated" && m.cards.some((c: any) => c.id === card.id && c.column === "done"));

    // A server starting again reads the same board.
    const reopened = new Board(join(dataDir, "board.json"), {
      hasProject: () => true,
      hasAgent: () => true,
      start: async () => "",
      session: () => undefined,
      broadcast: () => {},
    });
    const again = reopened.list(project.id).find((c) => c.id === card.id)!;
    assert.equal(again.column, "done");
    assert.equal(again.sessionId, sessionId);
  });

  it("gives each session in a git project a worktree of its own, and keeps the work when the worktree goes", async () => {
    const { ws, inbox } = await client();
    const git = (cwd: string, ...args: string[]) =>
      execFileSync("git", ["-C", cwd, "-c", "user.name=T", "-c", "user.email=t@t", ...args], { encoding: "utf8" }).trim();
    // A project cloned from an "origin", with one commit on main.
    const origin = mkdtempSync(join(tmpdir(), "kervan-origin-"));
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
    const repo = mkdtempSync(join(tmpdir(), "kervan-shared-"));
    execFileSync("git", ["clone", "-q", origin, repo], { stdio: "ignore" });
    git(repo, "checkout", "-q", "-b", "main");
    writeFileSync(join(repo, "page.html"), "start\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "first");
    git(repo, "push", "-q", "-u", "origin", "main");
    git(repo, "remote", "set-head", "origin", "main");
    const saved = await ask(ws, inbox, { type: "project.save", project: { name: "Paralel", path: repo } });
    const project = saved.projects.find((p: any) => p.name === "Paralel");

    const a = await idleSession(ws, inbox, { projectId: project.id });
    const b = await idleSession(ws, inbox, { projectId: project.id });
    const [aDir, bDir] = [sessions.workspace(a), sessions.workspace(b)];
    assert.notEqual(aDir, repo);
    assert.notEqual(aDir, bDir);
    await turn(ws, inbox, a, "write page.html from A");
    await turn(ws, inbox, b, "write page.html from B");
    assert.equal(readFileSync(join(aDir, "page.html"), "utf8").trim(), "from A");
    assert.equal(readFileSync(join(bDir, "page.html"), "utf8").trim(), "from B");
    assert.equal(readFileSync(join(repo, "page.html"), "utf8"), "start\n", "the project folder itself is untouched");

    // A pull request from A carries A's work only.
    const pr = await ask(ws, inbox, { type: "session.pullRequest", sessionId: a, title: "From A" });
    assert.equal(pr.type, "session.pullRequest.result", JSON.stringify(pr));
    assert.equal(git(origin, "show", `${pr.pullRequest.branch}:page.html`), "from A");
    assert.equal(git(origin, "rev-list", "--count", `main..${pr.pullRequest.branch}`), "1");

    // Removing B's worktree keeps B's uncommitted work on its branch, and leaves A and the project alone.
    const bBranch = sessions.list().find((s) => s.id === b)!.branch!;
    assert.equal((await ask(ws, inbox, { type: "session.archive", sessionId: b, archived: true, removeWorktree: true })).type, "ok");
    assert.equal(existsSync(bDir), false);
    assert.equal(git(repo, "show", `${bBranch}:page.html`), "from B");
    assert.equal(readFileSync(join(aDir, "page.html"), "utf8").trim(), "from A");
    assert.equal(readFileSync(join(repo, "page.html"), "utf8"), "start\n");
    // Unarchiving puts it back on its branch.
    assert.equal((await ask(ws, inbox, { type: "session.archive", sessionId: b, archived: false })).type, "ok");
    assert.equal(readFileSync(join(bDir, "page.html"), "utf8").trim(), "from B");

    // Asking for the shared folder still works.
    const shared = await idleSession(ws, inbox, { projectId: project.id, shared: true });
    assert.equal(sessions.workspace(shared), repo);
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

  it("gives a redacted report for Report a problem", async () => {
    const { ws, inbox } = await client();
    log("warn", "test line", { key: "ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnop", token: "0123456789abcdef0123456789abcdef" });
    const { report } = await ask(ws, inbox, { type: "diagnostics" });
    assert.equal(report.version, VERSION);
    assert.ok(report.agents.some((a: any) => a.id === "fake" && a.available));
    const line = report.logs.find((l: string) => l.includes("test line"));
    assert.ok(line, "recent warnings are included");
    assert.doesNotMatch(line, /sk-ant-abc|0123456789abcdef0123/);
  });

  it("redacts keys, tokens and bearer headers", () => {
    assert.equal(redact("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstu"), "OPENAI_API_KEY=…");
    assert.equal(redact("Authorization: Bearer abc.def"), "Authorization: Bearer …");
    assert.equal(redact("gemini AIzaSyA1234567890abcdefghijklmno ok"), "gemini AIza… ok");
    assert.equal(redact("token 25d3e6141117cbb29e47c47fc151382a9376c63f74422893 end"), "token … end");
    assert.equal(redact("nothing secret here"), "nothing secret here");
  });
});

describe("pull requests", () => {
  const git = (cwd: string, ...args: string[]) =>
    execFileSync("git", ["-C", cwd, "-c", "user.name=T", "-c", "user.email=t@t", ...args], { encoding: "utf8" }).trim();

  /** A clone of a bare "origin" with one commit on main. */
  function clone(): { work: string; origin: string } {
    const origin = mkdtempSync(join(tmpdir(), "kervan-origin-"));
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
    const work = mkdtempSync(join(tmpdir(), "kervan-work-"));
    execFileSync("git", ["clone", "-q", origin, work], { stdio: "ignore" });
    git(work, "checkout", "-q", "-b", "main");
    writeFileSync(join(work, "a.txt"), "one\n");
    git(work, "add", "-A");
    git(work, "commit", "-q", "-m", "first");
    git(work, "push", "-q", "-u", "origin", "main");
    git(work, "remote", "set-head", "origin", "main");
    return { work, origin };
  }

  it("reads GitHub remotes in their SSH and HTTPS forms", () => {
    assert.equal(githubRepoURL("git@github.com:enesyaks/Kervan.git"), "https://github.com/enesyaks/Kervan");
    assert.equal(githubRepoURL("https://github.com/enesyaks/Kervan"), "https://github.com/enesyaks/Kervan");
    assert.equal(githubRepoURL("https://x-token@github.com/enesyaks/Kervan.git/"), "https://github.com/enesyaks/Kervan");
    assert.equal(githubRepoURL("git@gitlab.com:a/b.git"), undefined);
  });

  it("moves work on main to its own branch, commits and pushes it, and leaves main alone", async () => {
    const { work, origin } = clone();
    writeFileSync(join(work, "a.txt"), "two\n");
    const result = await openPullRequest(work, { title: "Fix the greeting", body: "", sessionId: "abcdef1234" });
    assert.equal(result.base, "main");
    assert.equal(result.branch, "kervan/fix-the-greeting-abcdef12");
    assert.equal(result.created, false);
    assert.equal(result.url, undefined, "not a GitHub remote, so no compare page");
    assert.equal(git(origin, "log", "-1", "--format=%s", result.branch), "Fix the greeting");
    assert.equal(git(origin, "log", "-1", "--format=%s", "main"), "first");
    assert.equal(git(work, "status", "--porcelain"), "");
  });

  it("refuses when there is nothing to propose", async () => {
    const { work } = clone();
    git(work, "checkout", "-q", "-b", "kervan/empty");
    await assert.rejects(openPullRequest(work, { title: "Nothing", body: "", sessionId: "s1" }), /nothing to propose/);
  });
});

describe("web client", () => {
  let port = 0;
  let stop: () => Promise<void>;
  let web: WebAccess;
  before(async () => ({ port, stop, web } = await startServer()));
  after(async () => await stop());

  const url = (path: string) => `http://127.0.0.1:${port}${path}`;
  const keyProtocol = (token: string) => `kervan.key.${Buffer.from(token).toString("base64url")}`;
  const pair = (code: string) =>
    fetch(url("/v1/web/pair"), { method: "POST", body: JSON.stringify({ code, name: "Test phone" }) });

  /** The app, signed in with the server's key, asking for something. */
  async function app(message: Record<string, unknown>, reply: string): Promise<any> {
    const ws = openSocket(port);
    await opened(ws);
    const inbox = new Inbox(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    send(ws, { ...message, id: "a1" });
    const answer = await inbox.waitFor((m) => m.id === "a1");
    ws.close();
    assert.equal(answer.type, reply, JSON.stringify(answer));
    return answer;
  }

  it("is off until the app turns it on: no page, no files, no pairing", async () => {
    assert.equal((await fetch(url("/"))).status, 403);
    assert.equal((await fetch(url("/app.js"))).status, 404);
    assert.equal((await pair("AAAA-AAAA")).status, 403);
    const status = await app({ type: "web.enable", enabled: true }, "web.status.result");
    assert.equal(status.web.enabled, true);
    const page = await fetch(url("/"));
    assert.equal(page.status, 200);
    assert.match(page.headers.get("content-security-policy") ?? "", /script-src 'self'/);
    assert.equal((await fetch(url("/../src/main.ts"))).status, 404);
  });

  it("pairs a browser with a one-time code and gives it a key of its own", async () => {
    const { code } = await app({ type: "web.pair" }, "web.paired");
    assert.match(code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const answer = await pair(code.toLowerCase());
    assert.equal(answer.status, 200);
    const { token } = (await answer.json()) as { token: string };
    assert.notEqual(token, TEST_TOKEN);
    assert.equal((await pair(code)).status, 401, "a code works once");
    const check = (t: string) => fetch(url("/v1/check"), { headers: { authorization: `Bearer ${t}` } });
    assert.equal((await check(token)).status, 200);
    assert.ok(web.status().devices.some((d) => d.name === "Test phone"));
  });

  it("lets a paired browser work with sessions but nothing else, and never takes the server's key", async () => {
    const { code } = await app({ type: "web.pair" }, "web.paired");
    const { token } = (await (await pair(code)).json()) as { token: string };
    const ws = new WebSocket(url("/v1/ws").replace("http", "ws"), ["kervan", keyProtocol(token)]);
    await opened(ws);
    assert.equal(ws.protocol, "kervan");
    const inbox = new Inbox(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    send(ws, { type: "session.list", id: "l" });
    assert.equal((await inbox.waitFor((m) => m.id === "l")).type, "session.list.result");
    for (const type of ["web.pair", "agent.list", "node.invite"]) {
      send(ws, { type, id: type, name: "x" });
      assert.equal((await inbox.waitFor((m) => m.id === type)).code, "forbidden", type);
    }
    // Malformed restricted requests are refused the same way, without saying what a valid one looks like.
    send(ws, { type: "node.invite", id: "bare" });
    assert.equal((await inbox.waitFor((m) => m.id === "bare")).code, "forbidden");

    const closed = new Promise<number>((resolve) => ws.once("close", (code) => resolve(code)));
    const device = web.status().devices.at(-1)!;
    await app({ type: "web.revoke", deviceId: device.id }, "web.status.result");
    assert.equal(await closed, 4001, "revoking cuts the open connection");

    const master = new WebSocket(url("/v1/ws").replace("http", "ws"), ["kervan", keyProtocol(TEST_TOKEN)]);
    await assert.rejects(opened(master), /401/);
  });

  it("stops answering an address after ten wrong tries", async () => {
    const limited = await startServer();
    try {
      limited.web.setEnabled(true);
      const tryCode = () =>
        fetch(`http://127.0.0.1:${limited.port}/v1/web/pair`, { method: "POST", body: JSON.stringify({ code: "WRNG-CODE" }) });
      for (let i = 0; i < 10; i++) assert.equal((await tryCode()).status, 401);
      assert.equal((await tryCode()).status, 429);
      const device = await fetch(`http://127.0.0.1:${limited.port}/v1/check`, { headers: { authorization: "Bearer some-device-key" } });
      assert.equal(device.status, 429, "the same address waits for a device key check too");
      const app = await fetch(`http://127.0.0.1:${limited.port}/v1/check`, { headers: { authorization: `Bearer ${TEST_TOKEN}` } });
      assert.equal(app.status, 200, "the app's own key is never limited");
    } finally {
      await limited.stop();
    }
  });
});

describe("web access store", () => {
  it("lets a code lapse after ten minutes and keeps device keys only as hashes", () => {
    let now = Date.parse("2026-10-30T12:00:00Z");
    const file = join(mkdtempSync(join(tmpdir(), "kervan-web-")), "web.json");
    const access = new WebAccessStore(file, () => now);
    assert.throws(() => access.startPairing(), /turn web access on/);
    access.setEnabled(true);
    const late = access.startPairing();
    now += 10 * 60_000 + 1;
    assert.equal(access.redeem(late.code, "Late"), undefined);
    const fresh = access.startPairing();
    const paired = access.redeem(fresh.code, "Phone")!;
    assert.ok(access.authenticate(paired.token));
    assert.ok(!readFileSync(file, "utf8").includes(paired.token), "the key itself is never written");

    const ended: (string | null)[] = [];
    access.onRevoke((id) => ended.push(id));
    access.setEnabled(false);
    assert.equal(access.authenticate(paired.token), undefined, "off means no device gets in");
    assert.deepEqual(ended, [null]);
  });
});

describe("GitHub sign-in", () => {
  it("reads the account from either wording of gh auth status, and the code gh prints", () => {
    assert.equal(accountFrom("github.com\n  ✓ Logged in to github.com account enesyaks (keyring)"), "enesyaks");
    assert.equal(accountFrom("✓ Logged in to github.com as octo-cat (oauth_token)"), "octo-cat");
    assert.equal(accountFrom("You are not logged into any GitHub hosts."), undefined);
    assert.deepEqual(deviceCodeFrom("! First copy your one-time code: AB12-CD34\nOpen this URL to continue in your web browser: https://github.com/login/device"), {
      code: "AB12-CD34",
      url: "https://github.com/login/device",
    });
  });

  it("shows the code, then reports the account once the stand-in gh finishes", async () => {
    // A stand-in gh: login prints a code and succeeds; status says who is signed in once a login has finished.
    const bin = mkdtempSync(join(tmpdir(), "kervan-gh-"));
    const state = join(bin, "signed-in");
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh
case "$1 $2" in
  "--version "*) echo "gh version 9" ;;
  "auth login") echo "! First copy your one-time code: WXYZ-2345" >&2; echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2; sleep 0.2; touch "${state}" ;;
  "auth status") if [ -f "${state}" ]; then echo "  ✓ Logged in to github.com account tester (keyring)"; else echo "You are not logged into any GitHub hosts." >&2; exit 1; fi ;;
  "auth setup-git") ;;
  "auth logout") rm -f "${state}" ;;
esac
`,
      { mode: 0o755 },
    );
    const path = process.env.PATH;
    process.env.PATH = `${bin}:${path}`;
    try {
      const access = new GitHubAccess();
      assert.deepEqual(await access.status(), { available: true, signedIn: false, signingIn: false });
      const done = new Promise<string | undefined>((resolve) => {
        void access.connect(resolve).then((device) => assert.equal(device.code, "WXYZ-2345"));
      });
      assert.equal(await done, undefined);
      assert.deepEqual(await access.status(), { available: true, signedIn: true, signingIn: false, account: "tester" });
      await access.disconnect();
      assert.equal((await access.status()).signedIn, false);
    } finally {
      process.env.PATH = path;
    }
  });
});

describe("agent account sign-in", () => {
  it("reads the sign-in page from Claude's output, and the page and code from Codex's", () => {
    assert.deepEqual(
      loginPromptFrom("claude", "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=abc\nPaste code here if prompted > "),
      { url: "https://claude.com/cai/oauth/authorize?code=true&state=abc", needsCode: true },
    );
    assert.deepEqual(
      loginPromptFrom("codex", "1. Open this link in your browser\n   \u001b[94mhttps://auth.openai.com/codex/device\u001b[0m\n2. Enter this one-time code\n   \u001b[94mV5I6-7FSR3\u001b[0m"),
      { url: "https://auth.openai.com/codex/device", code: "V5I6-7FSR3", needsCode: false },
    );
    assert.equal(loginPromptFrom("claude", "Opening browser to sign in…"), undefined);
  });

  it("passes Claude the code from the page, and waits for Codex's device sign-in", async () => {
    // Stand-ins: Claude's login takes a code on its input and accepts only GOOD-CODE; Codex's prints a page and code.
    const bin = mkdtempSync(join(tmpdir(), "kervan-login-"));
    writeFileSync(
      join(bin, "claude"),
      `#!/bin/sh
case "$1 $2" in
  "auth login") echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=s1"; printf "Paste code here if prompted > "; read code; [ "$code" = "GOOD-CODE" ] && echo "Login successful." && exit 0; echo "OAuth error: invalid code"; exit 1 ;;
  "auth logout") echo "Logged out" ;;
esac
`,
      { mode: 0o755 },
    );
    writeFileSync(join(bin, "codex"), `#!/bin/sh\necho "   https://auth.openai.com/codex/device"\necho "   ABCD-12345"\nsleep 0.2\n`, { mode: 0o755 });
    process.env.KERVAN_CLAUDE_CLI = join(bin, "claude");
    process.env.KERVAN_CODEX_CLI = join(bin, "codex");
    try {
      const login = new AgentLogin();
      let finished: (error?: string) => void = () => {};
      let ended = new Promise<string | undefined>((resolve) => (finished = resolve));
      const claude = await login.start("claude", (error) => finished(error));
      assert.equal(claude.needsCode, true);
      assert.match(claude.url, /oauth\/authorize/);
      assert.ok(login.isSigningIn("claude"));
      assert.throws(() => login.submitCode("claude", "two\nlines"), /doesn't look like/);
      login.submitCode("claude", "  GOOD-CODE  ");
      assert.equal(await ended, undefined, "the right code signs it in");

      ended = new Promise<string | undefined>((resolve) => (finished = resolve));
      await login.start("claude", (error) => finished(error));
      login.submitCode("claude", "WRONG");
      assert.match((await ended) ?? "", /invalid code/, "a wrong code says why");
      assert.throws(() => login.submitCode("claude", "late"), /no sign-in is waiting/);

      ended = new Promise<string | undefined>((resolve) => (finished = resolve));
      const codex = await login.start("codex", (error) => finished(error));
      assert.deepEqual(codex, { agent: "codex", url: "https://auth.openai.com/codex/device", code: "ABCD-12345", needsCode: false });
      assert.equal(await ended, undefined);

      assert.throws(() => login.start("gemini", () => {}), /give it a key/);
      await login.signOut("claude");
    } finally {
      delete process.env.KERVAN_CLAUDE_CLI;
      delete process.env.KERVAN_CODEX_CLI;
    }
  });
});
