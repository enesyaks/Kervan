import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { projectBranches, pruneMergedBranches } from "../src/branches.ts";
import type { SessionInfo } from "../src/protocol.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" }).trim();

function commit(dir: string, file: string, message: string): void {
  writeFileSync(join(dir, file), `${message}\n`);
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", message);
}

function repository(dir: string): void {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  commit(dir, "README.md", "first");
}

const session = (id: string, branch: string, archived = false): SessionInfo =>
  ({ id, agent: "fake", title: id, status: "idle", createdAt: "", archived, skills: [], mcpServers: [], branch, projectId: "p" }) as SessionInfo;

describe("a project's branches", () => {
  let repo: string;

  before(() => {
    repo = join(mkdtempSync(join(tmpdir(), "kervan-branches-")), "repo");
    repository(repo);
    // A branch of the user's, one commit ahead and, once main moves, one behind.
    git(repo, "branch", "feature/login");
    git(repo, "checkout", "-q", "feature/login");
    commit(repo, "login.txt", "login");
    git(repo, "checkout", "-q", "main");
    // A session's branch with two commits of its own, and one already merged into main.
    git(repo, "branch", "kervan/fix-header-aaaaaaaa");
    git(repo, "checkout", "-q", "kervan/fix-header-aaaaaaaa");
    commit(repo, "header.txt", "header 1");
    commit(repo, "header.txt", "header 2");
    git(repo, "checkout", "-q", "main");
    git(repo, "branch", "kervan/done-bbbbbbbb");
    // Work a node came back with after its session moved to the server.
    git(repo, "branch", "kervan/fix-header-aaaaaaaa-from-laptop", "kervan/fix-header-aaaaaaaa");
    commit(repo, "main.txt", "main moves on");
  });

  it("lists the user's and Kervan's branches against the folder's branch, with their sessions", async () => {
    const listed = await projectBranches("p", repo, [session("s1", "kervan/fix-header-aaaaaaaa"), session("s2", "kervan/done-bbbbbbbb")]);
    assert.ok(listed);
    assert.equal(listed.base, "main");
    assert.equal(listed.current, "main");
    const byName = new Map(listed.branches.map((b) => [b.name, b]));

    const main = byName.get("main")!;
    assert.equal(main.base, true);
    assert.equal(main.current, true);
    assert.equal(main.subject, "main moves on");
    assert.deepEqual([main.ahead, main.behind, main.merged], [0, 0, false]);

    const feature = byName.get("feature/login")!;
    assert.deepEqual([feature.ahead, feature.behind, feature.merged, feature.kervan], [1, 1, false, undefined]);

    const fix = byName.get("kervan/fix-header-aaaaaaaa")!;
    assert.deepEqual([fix.ahead, fix.behind, fix.kervan, fix.sessionId], [2, 1, true, "s1"]);

    const done = byName.get("kervan/done-bbbbbbbb")!;
    assert.deepEqual([done.ahead, done.merged, done.sessionId], [0, true, "s2"]);

    // Saved from a node: tied to the session whose branch it was, and says which node.
    const saved = byName.get("kervan/fix-header-aaaaaaaa-from-laptop")!;
    assert.deepEqual([saved.kervan, saved.sessionId, saved.fromNode], [true, "s1", "laptop"]);
  });

  it("measures against origin's default branch and lists origin's branches that have no local one", async () => {
    const clone = join(mkdtempSync(join(tmpdir(), "kervan-branches-")), "clone");
    execFileSync("git", ["clone", "-q", repo, clone]);
    git(clone, "checkout", "-q", "-b", "local-only");
    const listed = await projectBranches("p", clone, []);
    assert.ok(listed);
    assert.equal(listed.base, "main");
    assert.equal(listed.current, "local-only");
    const names = listed.branches.map((b) => b.name);
    assert.ok(names.includes("origin/feature/login"));
    assert.ok(!names.includes("origin/main"), "main is local too");
    assert.ok(!names.includes("origin/HEAD"));
    assert.equal(listed.branches.find((b) => b.name === "origin/feature/login")!.remote, true);
  });

  it("is undefined for a folder that isn't a repository with a commit", async () => {
    const empty = mkdtempSync(join(tmpdir(), "kervan-branches-"));
    assert.equal(await projectBranches("p", empty, []), undefined);
  });

  it("prunes only Kervan's merged branches that no live session or worktree uses", async () => {
    const dir = join(mkdtempSync(join(tmpdir(), "kervan-branches-")), "repo");
    repository(dir);
    for (const name of ["kervan/old-11111111", "kervan/live-22222222", "kervan/wt-33333333", "kervan/archived-44444444", "user-branch"]) git(dir, "branch", name);
    git(dir, "branch", "kervan/unmerged-55555555");
    git(dir, "checkout", "-q", "kervan/unmerged-55555555");
    commit(dir, "x.txt", "own work");
    git(dir, "checkout", "-q", "main");
    git(dir, "worktree", "add", "-q", join(dir, "..", "wt"), "kervan/wt-33333333");

    const result = await pruneMergedBranches(dir, [session("a", "kervan/live-22222222"), session("b", "kervan/archived-44444444", true)]);
    assert.deepEqual(result.deleted.sort(), ["kervan/archived-44444444", "kervan/old-11111111"]);
    assert.deepEqual(result.kept.sort(), ["kervan/live-22222222", "kervan/wt-33333333"]);
    const left = git(dir, "branch", "--format=%(refname:short)").split("\n").sort();
    assert.deepEqual(left, ["kervan/live-22222222", "kervan/unmerged-55555555", "kervan/wt-33333333", "main", "user-branch"]);
  });
});

describe("project.branches over the socket", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `b${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id, 15_000);
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

  it("answers with the branches, or none for a folder without git, and prunes on request", async () => {
    const plain = await sessions.projects!.save({ name: "Gitsiz" });
    const none = await call({ type: "project.branches", projectId: plain.id });
    assert.equal(none.type, "project.branches.result", none.message);
    assert.equal(none.branches, undefined);

    const project = await sessions.projects!.save({ name: "Dallı" });
    repository(project.path);
    git(project.path, "branch", "kervan/merged-66666666");
    const listed = await call({ type: "project.branches", projectId: project.id });
    assert.deepEqual(listed.branches.branches.map((b: any) => b.name).sort(), ["kervan/merged-66666666", "main"]);

    const pruned = await call({ type: "project.branches.prune", projectId: project.id });
    assert.deepEqual(pruned.deleted, ["kervan/merged-66666666"]);
    assert.deepEqual(pruned.branches.branches.map((b: any) => b.name), ["main"]);

    assert.match((await call({ type: "project.branches", projectId: "yok" })).message, /no project 'yok'/);
  });
});
