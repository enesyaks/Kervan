import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { NodeAgent } from "../src/node-agent.ts";
import { applyBundle, branchTip, bundleBranch, cloneBundle, commitTurn, ensureBranch } from "../src/projectcopy.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, fakeAgent, openSocket, opened, send, startServer } from "./helpers.ts";

const NODE_TOKEN = "node-token-0123456789";

const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" }).trim();

/** A repository with one commit on main. */
function repository(dir: string): string {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "README.md"), "# proje\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
  return git(dir, "rev-parse", "HEAD");
}

describe("a project worked on from a node", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent;
  let old: NodeAgent;
  const nodeDir = mkdtempSync(join(tmpdir(), "kervan-node-"));
  const oldDir = mkdtempSync(join(tmpdir(), "kervan-oldnode-"));
  let n = 0;

  const startNode = () => {
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
    node.start();
  };
  const connected = (name: string, value: boolean, from: number) =>
    inbox.waitFor((m) => inbox.received.indexOf(m) >= from && m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === name && x.connected === value));
  const saveAgent = async (id: string, nodeName: string) => {
    send(ws, { type: "agent.save", id: `a-${id}`, agent: { id, name: id, command: fakeAgent.command, args: fakeAgent.args, node: nodeName } });
    await inbox.waitFor((m) => m.type === "agent.list.result" && m.id === `a-${id}`, 15_000);
  };
  const create = async (fields: object): Promise<any> => {
    const id = `c${++n}`;
    send(ws, { type: "session.create", id, ...fields });
    return inbox.waitFor((m) => (m.type === "session.created" || m.type === "error") && m.id === id, 15_000);
  };
  /** Sends a message and waits until the session is idle again, i.e. the turn and its sync are done. */
  const turn = async (sessionId: string, text: string) => {
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id: `p${++n}`, sessionId, text });
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end", 15_000);
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);
    return inbox.received.slice(seen).filter((m) => m.type === "session.event" && m.sessionId === sessionId).map((m) => m.event);
  };

  before(async () => {
    ({ port, sessions, stop } = await startServer({ nodeToken: NODE_TOKEN }));
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const mark = inbox.received.length;
    startNode();
    // A node from before projects on nodes: its hello doesn't say it can hold a copy.
    old = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "eski", workspacesDir: oldDir, runner: new LocalAcpRunner(), features: ["orchestra"] });
    old.start();
    await connected("kutu", true, mark);
    await connected("eski", true, mark);
    await saveAgent("uzak", "kutu");
    await saveAgent("eskiajan", "eski");
  });

  after(async () => {
    node?.stop();
    old?.stop();
    ws.terminate();
    await stop();
  });

  it("tells the app which nodes can work on projects", () => {
    const listed = sessions.nodes!.list();
    assert.ok(listed.find((x) => x.name === "kutu")?.features?.includes("projects"));
    assert.ok(!listed.find((x) => x.name === "eski")?.features?.includes("projects"));
  });

  it("refuses a project that isn't a git repository with a commit, and an older node, saying why", async () => {
    const plain = await sessions.projects!.save({ name: "Düz klasör" });
    const gitProject = await sessions.projects!.save({ name: "Git" });
    repository(gitProject.path);

    const notGit = await create({ agent: "uzak", projectId: plain.id });
    assert.equal(notGit.type, "error");
    assert.match(notGit.message, /project 'Düz klasör' isn't a git repository with at least one commit/);
    // An empty repository has nothing to copy either.
    git(plain.path, "init", "-q");
    assert.match((await create({ agent: "uzak", projectId: plain.id })).message, /isn't a git repository with at least one commit/);
    assert.throws(() => sessions.board!.save({ projectId: plain.id, title: "Kart", prompt: "yap", agent: "uzak" }), /isn't a git repository/);

    const oldNode = await create({ agent: "eskiajan", projectId: gitProject.id });
    assert.equal(oldNode.type, "error");
    assert.match(oldNode.message, /node 'eski' can't work on projects yet; update Kervan on it first/);
    assert.throws(() => sessions.board!.save({ projectId: gitProject.id, title: "Kart", prompt: "yap", agent: "eskiajan" }), /update Kervan on it first/);
    const task = { title: "Görev", agent: "eskiajan", prompt: "yap", projectId: gitProject.id, when: { kind: "interval", minutes: 60 }, timeZone: "UTC" };
    assert.throws(() => sessions.scheduler!.save(task), /update Kervan on it first/);

    // A node that can is saved fine; it runs when it comes due.
    const card = sessions.board!.save({ projectId: gitProject.id, title: "Kart", prompt: "yap", agent: "uzak" });
    assert.equal(card.agent, "uzak");
  });

  let projectPath = "";
  let mainHead = "";
  let sessionId = "";
  let branch = "";

  it("gives the node a working copy of the project on the session's own branch", async () => {
    const project = await sessions.projects!.save({ name: "Uygulama" });
    projectPath = project.path;
    mainHead = repository(projectPath);

    const created = await create({ agent: "uzak", projectId: project.id });
    assert.equal(created.type, "session.created", created.message);
    sessionId = created.session.id;
    branch = created.session.branch;
    assert.match(branch, /^kervan\/[a-z0-9-]+$/);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);

    const copy = join(nodeDir, sessionId);
    assert.equal(readFileSync(join(copy, "README.md"), "utf8"), "# proje\n");
    assert.equal(git(copy, "branch", "--show-current"), branch);
    assert.equal(git(copy, "rev-parse", "HEAD"), mainHead);
    assert.equal(git(copy, "remote"), "", "the copy has no remote: it only talks to the hub through Kervan");
    assert.equal(await branchTip(projectPath, branch), mainHead, "the hub has the branch from the start");
    assert.equal(git(projectPath, "branch", "--show-current"), "main");
  });

  it("brings a turn's changes back to the hub as the session's branch, leaving the project's checkout alone", async () => {
    const events = await turn(sessionId, "write yeni.txt merhaba");
    assert.ok(events.some((e) => e.kind === "notice" && /Work sent to the server: branch kervan\//.test(e.text)), JSON.stringify(events));

    assert.equal(git(projectPath, "show", `${branch}:yeni.txt`), "merhaba");
    assert.equal(git(projectPath, "rev-list", "--count", branch), "2");
    assert.equal(git(projectPath, "rev-parse", `${branch}~1`), mainHead);
    // The project folder is exactly as it was: same branch, same commit, no new files.
    assert.equal(git(projectPath, "branch", "--show-current"), "main");
    assert.equal(git(projectPath, "rev-parse", "HEAD"), mainHead);
    assert.equal(git(projectPath, "status", "--porcelain"), "");
    assert.ok(!existsSync(join(projectPath, "yeni.txt")));
    // Nothing is left behind.
    assert.equal(git(projectPath, "for-each-ref", "refs/kervan-incoming"), "");
  });

  it("sends nothing after a turn that changed nothing", async () => {
    const before = await branchTip(projectPath, branch);
    const events = await turn(sessionId, "whoami");
    assert.ok(!events.some((e) => e.kind === "notice"), JSON.stringify(events));
    assert.equal(await branchTip(projectPath, branch), before);
    assert.equal(git(projectPath, "rev-list", "--count", branch), "2");
  });

  it("brings work the node had when it went away as soon as the session resumes there", async () => {
    let mark = inbox.received.length;
    node.stop();
    await connected("kutu", false, mark);
    // What the agent wrote in a turn the node didn't get to send (written here as if by it).
    writeFileSync(join(nodeDir, sessionId, "yarim.txt"), "yarım kalan iş");
    mark = inbox.received.length;
    startNode();
    await connected("kutu", true, mark);

    const events = await turn(sessionId, "whoami");
    assert.ok(events.some((e) => e.kind === "notice" && /Work sent to the server/.test(e.text)), JSON.stringify(events));
    assert.equal(git(projectPath, "show", `${branch}:yarim.txt`), "yarım kalan iş");
    assert.equal(git(projectPath, "branch", "--show-current"), "main");
  });

  it("pushes the session's branch from the server and proposes it, without touching the project folder", async () => {
    // The project's real repository, where work goes once it has piled up on the server.
    const origin = join(mkdtempSync(join(tmpdir(), "kervan-origin-")), "origin.git");
    execFileSync("git", ["init", "-q", "--bare", origin]);
    git(projectPath, "remote", "add", "origin", origin);
    git(projectPath, "push", "-q", "origin", "main");
    await turn(sessionId, "write son.txt bitti");

    const id = `pr${++n}`;
    send(ws, { type: "session.pullRequest", id, sessionId, title: "Node'dan gelen iş", body: "" });
    const answer = await inbox.waitFor((m) => m.id === id && (m.type === "session.pullRequest.result" || m.type === "error"), 30_000);
    assert.equal(answer.type, "session.pullRequest.result", answer.message);
    assert.equal(answer.pullRequest.branch, branch);
    assert.equal(answer.pullRequest.base, "main");
    assert.equal(git(origin, "show", `${branch}:son.txt`), "bitti");
    assert.equal(git(origin, "show", `${branch}:yeni.txt`), "merhaba");
    assert.equal(git(origin, "rev-parse", branch), git(projectPath, "rev-parse", branch), "exactly what the server holds");
    assert.equal(git(projectPath, "branch", "--show-current"), "main");
    assert.equal(git(projectPath, "status", "--porcelain"), "");

    // Once main has it all (the pull request merged), there is nothing left to propose.
    git(origin, "update-ref", "refs/heads/main", git(origin, "rev-parse", branch));
    git(projectPath, "fetch", "-q", "origin");
    send(ws, { type: "session.pullRequest", id: `${id}b`, sessionId, title: "Yine", body: "" });
    const again = await inbox.waitFor((m) => m.id === `${id}b`, 30_000);
    assert.match(again.message ?? "", /nothing to propose/);
  });
});

describe("bringing a node's work into the hub's repository", () => {
  const root = mkdtempSync(join(tmpdir(), "kervan-copy-"));
  const hub = join(root, "hub");
  const copy = join(root, "node", "copy");
  const branch = "kervan/deneme-12345678";
  let start = "";

  before(async () => {
    repository(hub);
    start = await ensureBranch(hub, branch);
    await bundleBranch(hub, branch, join(root, "clone.bundle"));
    await cloneBundle(copy, join(root, "clone.bundle"), branch);
  });

  it("leaves the branch as it was when a bundle arrives cut short", async () => {
    writeFileSync(join(copy, "a.txt"), "a");
    const result = await commitTurn(copy, branch, start, "turn", join(root, "turn.bundle"));
    assert.equal(result.changed, true);
    // A node that went away midway: only part of the bundle made it.
    const cut = join(root, "cut.bundle");
    writeFileSync(cut, readFileSync(join(root, "turn.bundle")).subarray(0, 200));
    await assert.rejects(applyBundle(hub, branch, cut, start));
    assert.equal(await branchTip(hub, branch), start);
    assert.equal(git(hub, "for-each-ref", "refs/kervan-incoming"), "");

    // The whole bundle then applies.
    const applied = await applyBundle(hub, branch, join(root, "turn.bundle"), start);
    assert.deepEqual(applied, { moved: true, head: result.head });
  });

  it("refuses to move a branch that moved on the hub meanwhile, rather than lose either side", async () => {
    const tip = (await branchTip(hub, branch))!;
    writeFileSync(join(copy, "b.txt"), "b");
    await commitTurn(copy, branch, tip, "turn 2", join(root, "turn2.bundle"));
    // Someone committed on the branch here in between.
    git(hub, "worktree", "add", "-q", join(root, "wt"), branch);
    writeFileSync(join(root, "wt", "c.txt"), "c");
    git(join(root, "wt"), "add", "-A");
    git(join(root, "wt"), "commit", "-q", "-m", "on the hub");
    const moved = (await branchTip(hub, branch))!;
    await assert.rejects(applyBundle(hub, branch, join(root, "turn2.bundle"), moved), /has commits the node's copy doesn't/);
    assert.equal(await branchTip(hub, branch), moved);
  });

  it("writes no bundle for a turn without changes", async () => {
    const head = git(copy, "rev-parse", "HEAD");
    const file = join(root, "none.bundle");
    assert.deepEqual(await commitTurn(copy, branch, head, "nothing", file), { head, changed: false });
    assert.ok(!existsSync(file));
  });
});

describe("continuing a node's project session on the server", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent;
  const nodeDir = mkdtempSync(join(tmpdir(), "kervan-node-"));
  let n = 0;
  let projectPath = "";
  let mainHead = "";
  let sessionId = "";
  let branch = "";

  const startNode = () => {
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
    node.start();
  };
  const connected = (value: boolean, from: number) =>
    inbox.waitFor((m) => inbox.received.indexOf(m) >= from && m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "kutu" && x.connected === value));
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const turn = async (text: string) => {
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id: `p${++n}`, sessionId, text });
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end", 15_000);
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);
    const events = inbox.received.slice(seen).filter((m) => m.type === "session.event" && m.sessionId === sessionId).map((m) => m.event);
    return events.filter((e) => e.kind === "agent_message_chunk").map((e) => e.text).join("");
  };

  before(async () => {
    ({ port, sessions, stop } = await startServer({ nodeToken: NODE_TOKEN }));
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const mark = inbox.received.length;
    startNode();
    await connected(true, mark);
    await call({ type: "agent.save", agent: { id: "uzak", name: "Uzak", command: fakeAgent.command, args: fakeAgent.args, node: "kutu" } });

    const project = await sessions.projects!.save({ name: "Devralınan" });
    projectPath = project.path;
    mainHead = repository(projectPath);
    const created = await call({ type: "session.create", agent: "uzak", projectId: project.id });
    sessionId = created.session.id;
    branch = created.session.branch;
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);
    await turn("write bir.txt ilk tur");
  });

  after(async () => {
    node?.stop();
    ws.terminate();
    await stop();
  });

  it("refuses what can't continue on the server", async () => {
    const plain = await call({ type: "session.create", agent: "uzak" });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === plain.session.id && m.session.status === "idle", 15_000);
    assert.match((await call({ type: "session.takeover", sessionId: plain.session.id })).message, /only a project session on a node/);
    assert.match((await call({ type: "session.takeover", sessionId, agent: "uzak" })).message, /doesn't run on this server/);
    assert.equal((await call({ type: "session.takeover", sessionId, agent: "yok" })).code, "unknown_agent");
    assert.equal(sessions.list().find((s) => s.id === sessionId)?.agent, "uzak", "nothing changed");
  });

  it("continues on the server from the branch, with the conversation so far, when the node is gone", async () => {
    let mark = inbox.received.length;
    node.stop();
    await connected(false, mark);
    // The turn the node was in when it went away: written, never sent.
    writeFileSync(join(nodeDir, sessionId, "iki.txt"), "gönderilmedi");

    const answer = await call({ type: "session.takeover", sessionId });
    assert.equal(answer.type, "ok", answer.message);
    const info = sessions.list().find((s) => s.id === sessionId)!;
    assert.equal(info.agent, "fake", "the first agent on this server");
    assert.equal(info.status, "idle");
    assert.equal(info.branch, branch);
    assert.equal(info.movedFrom?.node, "kutu");

    const worktree = sessions.workspace(sessionId);
    assert.match(worktree, new RegExp(`worktree-${sessionId}$`), "a worktree on this server, as project sessions here have");
    assert.equal(git(worktree, "branch", "--show-current"), branch);
    assert.equal(readFileSync(join(worktree, "bir.txt"), "utf8"), "ilk tur");
    assert.ok(!existsSync(join(worktree, "iki.txt")), "what the node never sent isn't here");
    assert.equal(git(projectPath, "branch", "--show-current"), "main");
    assert.equal(git(projectPath, "rev-parse", "HEAD"), mainHead);

    // The new agent is told where it is and what was said, with the next message.
    const preface = await turn("prefacecheck");
    assert.match(preface, /started with another agent on node 'kutu'/);
    assert.match(preface, new RegExp(`branch ${branch}`));
    assert.match(preface, /User: write bir.txt ilk tur/);
    assert.match(preface, /Agent: wrote bir.txt/);
    // And it works there: changes stay in the worktree on this server.
    await turn("write uc.txt sunucuda");
    assert.equal(readFileSync(join(worktree, "uc.txt"), "utf8"), "sunucuda");

    // The node comes back: what it never sent is kept, on a branch of its own.
    mark = inbox.received.length;
    const tip = git(projectPath, "rev-parse", branch);
    startNode();
    await connected(true, mark);
    const notice = await inbox.waitFor(
      (m) => inbox.received.indexOf(m) >= mark && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "notice" && /came back with work/.test(m.event.text),
      15_000,
    );
    assert.match(notice.event.text, new RegExp(`${branch}-from-kutu`));
    assert.equal(git(projectPath, "show", `${branch}-from-kutu:iki.txt`), "gönderilmedi");
    assert.equal(git(projectPath, "rev-parse", branch), tip, "the session's own branch is left alone");
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.movedFrom?.collected === true, 15_000);
  });
});

describe("an unattended task whose node goes away mid-turn", () => {
  /** A server, a node with agent "uzak", a git project, and a board-style task asking a question nobody answers. */
  async function setUp(minutes: number) {
    const nodeDir = mkdtempSync(join(tmpdir(), "kervan-node-"));
    const server = await startServer({ nodeToken: NODE_TOKEN, limits: { nodeTakeoverMinutes: minutes } });
    const ws = openSocket(server.port);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    let node: NodeAgent | undefined;
    const startNode = () => {
      node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${server.port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
      node.start();
    };
    const connected = (value: boolean, from: number) =>
      inbox.waitFor((m) => inbox.received.indexOf(m) >= from && m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "kutu" && x.connected === value));
    let mark = inbox.received.length;
    startNode();
    await connected(true, mark);
    send(ws, { type: "agent.save", id: "a1", agent: { id: "uzak", name: "Uzak", command: fakeAgent.command, args: fakeAgent.args, node: "kutu" } });
    await inbox.waitFor((m) => m.type === "agent.list.result" && m.id === "a1", 15_000);
    const project = await server.sessions.projects!.save({ name: "Gece işi" });
    repository(project.path);
    // Like a card: nobody watches it, and it stops at a question (mid-turn) when the node goes away.
    const id = await server.sessions.runTask({ agent: "uzak", title: "Gece", prompt: "askperm: edit dosya", projectId: project.id });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === id && m.event.kind === "permission_request", 15_000);
    mark = inbox.received.length;
    node!.stop();
    await connected(false, mark);
    const events = (from: number) => inbox.received.slice(from).filter((m) => m.type === "session.event" && m.sessionId === id).map((m) => m.event);
    const done = async () => {
      node?.stop();
      ws.terminate();
      await server.stop();
    };
    return { ...server, inbox, id, mark, startNode, connected, events, done };
  }

  it("continues on the server and carries on with the task once the node has been away long enough", async () => {
    const t = await setUp(0.01); // under a second
    try {
      const prompt = await t.inbox.waitFor(
        (m) => t.inbox.received.indexOf(m) >= t.mark && m.type === "session.event" && m.sessionId === t.id && m.event.kind === "user_message" && /didn't come back/.test(m.event.text),
        15_000,
      );
      assert.match(prompt.event.text, /cut off in the middle of this task/);
      await t.inbox.waitFor((m) => t.inbox.received.indexOf(m) > t.inbox.received.indexOf(prompt) && m.type === "session.event" && m.sessionId === t.id && m.event.kind === "turn_end", 15_000);
      const info = t.sessions.list().find((s) => s.id === t.id)!;
      assert.equal(info.agent, "fake");
      assert.equal(info.movedFrom?.node, "kutu");
      const notices = t.events(t.mark).filter((e) => e.kind === "notice").map((e) => e.text);
      assert.ok(notices.some((text) => /went away in the middle of this task/.test(text)), notices.join("\n"));
      assert.ok(notices.some((text) => /was away for .* so it continues on the server/.test(text)), notices.join("\n"));
    } finally {
      await t.done();
    }
  });

  it("carries on on the node instead when it's back in time", async () => {
    const t = await setUp(1);
    try {
      const mark = t.inbox.received.length;
      t.startNode();
      await t.connected(true, mark);
      const prompt = await t.inbox.waitFor(
        (m) => t.inbox.received.indexOf(m) >= mark && m.type === "session.event" && m.sessionId === t.id && m.event.kind === "user_message",
        15_000,
      );
      assert.match(prompt.event.text, /It's back: carry on/);
      await t.inbox.waitFor((m) => t.inbox.received.indexOf(m) > t.inbox.received.indexOf(prompt) && m.type === "session.event" && m.sessionId === t.id && m.event.kind === "turn_end", 15_000);
      const info = t.sessions.list().find((s) => s.id === t.id)!;
      assert.equal(info.agent, "uzak", "still on the node");
      assert.equal(info.movedFrom, undefined);
    } finally {
      await t.done();
    }
  });
});

describe("skills for agents on a node", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent;
  let old: NodeAgent;
  const nodeDir = mkdtempSync(join(tmpdir(), "kervan-node-"));
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const idle = (id: string) => inbox.waitFor((m) => m.type === "session.updated" && m.session.id === id && m.session.status === "idle", 15_000);

  before(async () => {
    let port: number;
    let dataDir: string;
    ({ port, sessions, stop, dataDir } = await startServer({ nodeToken: NODE_TOKEN }));
    mkdirSync(join(dataDir, "skills", "test-yaz", "ornekler"), { recursive: true });
    writeFileSync(join(dataDir, "skills", "test-yaz", "SKILL.md"), "---\nname: test-yaz\ndescription: Writes tests first.\n---\nWrite a failing test.\n");
    writeFileSync(join(dataDir, "skills", "test-yaz", "ornekler", "bir.md"), "örnek");
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const mark = inbox.received.length;
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
    node.start();
    // Can hold a project copy, but has no code for skills.
    old = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "eski", workspacesDir: mkdtempSync(join(tmpdir(), "kervan-oldnode-")), runner: new LocalAcpRunner(), features: ["orchestra", "projects"] });
    old.start();
    for (const name of ["kutu", "eski"]) {
      await inbox.waitFor((m) => inbox.received.indexOf(m) >= mark && m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === name && x.connected));
    }
    await call({ type: "agent.save", agent: { id: "uzak", name: "Uzak", command: fakeAgent.command, args: fakeAgent.args, node: "kutu" } });
    await call({ type: "agent.save", agent: { id: "eskiajan", name: "Eski", command: fakeAgent.command, args: fakeAgent.args, node: "eski" } });
  });

  after(async () => {
    node?.stop();
    old?.stop();
    ws.terminate();
    await stop();
  });

  it("copies an agent's skills into its folder on the node, files and all", async () => {
    const created = await call({ type: "session.create", agent: "uzak", skills: ["test-yaz"] });
    assert.equal(created.type, "session.created", created.message);
    await idle(created.session.id);
    const skills = join(nodeDir, created.session.id, ".kervan", "skills", "test-yaz");
    assert.match(readFileSync(join(skills, "SKILL.md"), "utf8"), /Write a failing test/);
    assert.equal(readFileSync(join(skills, "ornekler", "bir.md"), "utf8"), "örnek");
  });

  it("keeps the skills out of a project copy's commits", async () => {
    const project = await sessions.projects!.save({ name: "Skill'li proje" });
    repository(project.path);
    const created = await call({ type: "session.create", agent: "uzak", skills: ["test-yaz"], projectId: project.id });
    assert.equal(created.type, "session.created", created.message);
    const { id, branch } = created.session;
    await idle(id);
    assert.ok(existsSync(join(nodeDir, id, ".kervan", "skills", "test-yaz", "SKILL.md")), "copied after the clone");
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id: `p${++n}`, sessionId: id, text: "write yeni.txt iş" });
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === id && m.event.kind === "turn_end", 15_000);
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.updated" && m.session.id === id && m.session.status === "idle", 15_000);
    assert.equal(git(project.path, "show", `${branch}:yeni.txt`), "iş");
    assert.equal(git(project.path, "ls-tree", "-r", "--name-only", branch).split("\n").filter((f) => f.startsWith(".kervan")).length, 0);
  });

  it("refuses skills for an older node, saying to update it", async () => {
    const refused = await call({ type: "session.create", agent: "eskiajan", skills: ["test-yaz"] });
    assert.match(refused.message, /node 'eski' can't take skills yet; update Kervan on it first/);
  });
});
