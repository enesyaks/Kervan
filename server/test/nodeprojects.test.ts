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
