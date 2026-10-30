import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { branchName } from "../src/worktree.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", ["-C", cwd, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" });

describe("budgets, limits and helper worktrees", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;

  const create = async (extra: object = {}) => {
    const id = `c${++n}`;
    send(ws, { type: "session.create", id, agent: "fake", ...extra });
    const { session } = await inbox.waitFor((m) => m.type === "session.created" && m.id === id);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle");
    return session;
  };

  const prompt = (sessionId: string, text: string) => {
    const id = `p${++n}`;
    send(ws, { type: "session.prompt", id, sessionId, text });
    return inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end" && m.event.seq > 1);
  };

  /** A lead whose folder is a git repository with one commit. */
  const repoLead = async () => {
    const lead = await create({ orchestrate: true });
    const dir = sessions.workspace(lead.id);
    git(dir, "init", "-q", "-b", "main");
    writeFileSync(join(dir, "README.md"), "Kervan\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "ilk");
    return { lead, dir };
  };

  before(async () => {
    let port = 0;
    ({ port, sessions, stop } = await startServer({ limits: { maxHelpers: 2, helperTurnMinutes: 0.002 } }));
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

  it("names branches readably", () => {
    assert.equal(branchName("Test yazarı İşçi", "abcdef1234"), "kervan/test-yazari-isci-abcdef12");
    assert.equal(branchName("!!!", "abcdef1234"), "kervan/helper-abcdef12");
  });

  it("keeps the usage an agent reports", async () => {
    const session = await create();
    await prompt(session.id, "usage 0.25");
    assert.deepEqual(sessions.list().find((s) => s.id === session.id)?.usage, { contextUsed: 1200, contextSize: 200_000, costUsd: 0.25 });
  });

  it("stops a lead and its helpers once their budget is spent, and refuses new helpers", async () => {
    const lead = await create({ orchestrate: true, budgetUsd: 0.5 });
    assert.equal(lead.budgetUsd, 0.5);
    const helper = await sessions.startHelper(lead.id, { name: "Pahalı", task: "usage 0.3", agent: "fake" });
    await sessions.waitForHelper(lead.id, helper.helperId, 5000);
    await sessions.startHelper(lead.id, { name: "Ucuz", task: "x", agent: "fake" }); // $0.30 of $0.50 so far

    await prompt(lead.id, "usage 0.2");
    assert.equal(sessions.crewCost(lead.id), 0.5);
    const notice = sessions.history(lead.id).find((e) => e.kind === "notice");
    assert.match(notice && notice.kind === "notice" ? notice.text : "", /Budget used up: \$0\.50 of \$0\.5/);
    await assert.rejects(sessions.startHelper(lead.id, { name: "Fazla", task: "x", agent: "fake" }), /budget of \$0\.5/);
    assert.throws(() => sessions.messageHelper(lead.id, helper.helperId, "devam"), /budget/);
  });

  it("refuses a budget that isn't a positive amount", async () => {
    send(ws, { type: "session.create", id: "bad", agent: "fake", orchestrate: true, budgetUsd: -1 });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "bad")).message, /budgetUsd/);
  });

  it("stops a helper turn that runs past the time limit", async () => {
    const lead = await create({ orchestrate: true });
    const helper = await sessions.startHelper(lead.id, { name: "Yavaş", task: "slow", agent: "fake" });
    await sessions.waitForHelper(lead.id, helper.helperId, 5000);
    const notice = sessions.history(helper.helperId).find((e) => e.kind === "notice");
    assert.match(notice && notice.kind === "notice" ? notice.text : "", /turn time limit/);
  });

  it("uses the configured helper limit", async () => {
    const lead = await create({ orchestrate: true });
    await sessions.startHelper(lead.id, { name: "A", task: "x", agent: "fake" });
    await sessions.startHelper(lead.id, { name: "B", task: "x", agent: "fake" });
    await assert.rejects(sessions.startHelper(lead.id, { name: "C", task: "x", agent: "fake" }), /at most 2 helpers/);
  });

  it("works in the lead's folder when it isn't a git repository, and says so", async () => {
    const lead = await create({ orchestrate: true });
    const helper = await sessions.startHelper(lead.id, { name: "Ortak", task: "x", agent: "fake" });
    assert.equal(helper.branch, undefined);
    assert.match(helper.note ?? "", /not a git repository/);
    assert.equal(sessions.workspace(helper.helperId), sessions.workspace(lead.id));
    await assert.rejects(sessions.helperDiff(lead.id, helper.helperId), /not on a branch/);
  });

  it("gives a helper its own branch, shows its changes and merges them", async () => {
    const { lead, dir } = await repoLead();
    const helper = await sessions.startHelper(lead.id, { name: "Test yazarı", task: "x", agent: "fake" });
    assert.match(helper.branch ?? "", /^kervan\/test-yazari-/);
    const workdir = sessions.workspace(helper.helperId);
    assert.notEqual(workdir, dir);
    assert.ok(existsSync(join(workdir, "README.md")), "the worktree starts from the lead's commit");

    await sessions.waitForHelper(lead.id, helper.helperId, 5000);
    writeFileSync(join(workdir, "test.py"), "assert True\n");
    const diff = await sessions.helperDiff(lead.id, helper.helperId);
    assert.match(diff.stat, /test\.py/);
    assert.match(diff.patch, /\+assert True/);
    assert.ok(!existsSync(join(dir, "test.py")), "nothing reaches the lead before the merge");

    const result = await sessions.mergeHelper(lead.id, helper.helperId);
    assert.equal(result.merged, true);
    assert.equal(readFileSync(join(dir, "test.py"), "utf8"), "assert True\n");
    assert.match(git(dir, "log", "-1", "--format=%s"), /Kervan: merge Test yazarı/);
  });

  it("reports conflicts and leaves the lead's folder as it was", async () => {
    const { lead, dir } = await repoLead();
    const helper = await sessions.startHelper(lead.id, { name: "Çakışan", task: "x", agent: "fake" });
    await sessions.waitForHelper(lead.id, helper.helperId, 5000);
    writeFileSync(join(sessions.workspace(helper.helperId), "README.md"), "yardımcı\n");
    writeFileSync(join(dir, "README.md"), "ana ajan\n");
    git(dir, "commit", "-q", "-am", "ana ajanın değişikliği");

    const result = await sessions.mergeHelper(lead.id, helper.helperId);
    assert.equal(result.merged, false);
    assert.deepEqual(result.merged === false && result.conflicts, ["README.md"]);
    assert.equal(readFileSync(join(dir, "README.md"), "utf8"), "ana ajan\n");
    assert.equal(git(dir, "status", "--porcelain"), "", "no half-done merge left behind");
  });
});
