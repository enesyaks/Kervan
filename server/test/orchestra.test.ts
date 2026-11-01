import assert from "node:assert/strict";
import { request } from "node:http";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { isOrchestraCall, orchestraSocketPath } from "../src/orchestra.ts";
import { MAX_HELPERS, type SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

describe("lead agents and helpers", () => {
  let port = 0;
  let sessions: SessionManager;
  let dataDir = "";
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

  const answer = (sessionId: string, match: RegExp, timeoutMs = 15_000) =>
    inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk" && match.test(m.event.text),
      timeoutMs,
    );

  before(async () => {
    ({ port, sessions, dataDir, stop } = await startServer());
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

  it("gives the orchestration tools only to leads", async () => {
    const lead = await create({ orchestrate: true });
    assert.equal(lead.orchestrate, true);
    send(ws, { type: "session.prompt", id: "p1", sessionId: lead.id, text: "mcpcheck" });
    await answer(lead.id, /^mcp: kervan$/);

    const plain = await create();
    send(ws, { type: "session.prompt", id: "p2", sessionId: plain.id, text: "mcpcheck" });
    await answer(plain.id, /^mcp: $/);
  });

  it("lets a lead start a helper, wait for it and read its reply", async () => {
    const lead = await create({ orchestrate: true });
    send(ws, { type: "session.prompt", id: "p3", sessionId: lead.id, text: "delegate: selam" });
    await answer(lead.id, /^helper said: echo: selam$/);

    const [helper] = sessions.helpers(lead.id);
    assert.equal(helper.name, "Yardımcı");
    const info = sessions.list().find((s) => s.id === helper.helperId)!;
    assert.equal(info.parentId, lead.id);
    assert.equal(info.orchestrate, undefined, "helpers can't start helpers of their own");
    assert.equal(sessions.workspace(helper.helperId), sessions.workspace(lead.id), "helper works in the lead's folder");

    const task = sessions.history(helper.helperId).find((e) => e.kind === "user_message");
    assert.deepEqual(task && [task.text, task.kind === "user_message" && task.from], ["selam", lead.id]);
  });

  it("tells helpers who they work for", async () => {
    const lead = await create({ orchestrate: true });
    send(ws, { type: "session.prompt", id: "p4", sessionId: lead.id, text: "delegate: prefacecheck" });
    const { event } = await answer(lead.id, /^helper said:/);
    assert.match(event.text, /helper agent named "Yardımcı", started by the lead agent/);
  });

  it("keeps leads to their own helpers and to the limit", async () => {
    const lead = await create({ orchestrate: true });
    const other = await create({ orchestrate: true });
    const first = await sessions.startHelper(lead.id, { name: "A", task: "bir", agent: "fake" });
    assert.throws(() => sessions.messageHelper(other.id, first.helperId, "hey"), /no helper/);
    await assert.rejects(sessions.startHelper(lead.id, { name: "B", task: "x", agent: "nope" }), /no agent named 'nope'/);

    const plain = await create();
    await assert.rejects(sessions.startHelper(plain.id, { name: "C", task: "x", agent: "fake" }), /can't start helpers/);

    for (let i = sessions.helpers(lead.id).length; i < MAX_HELPERS; i++) {
      await sessions.startHelper(lead.id, { name: `H${i}`, task: "x", agent: "fake" });
    }
    await assert.rejects(sessions.startHelper(lead.id, { name: "fazla", task: "x", agent: "fake" }), /at most/);

    const done = await sessions.waitForHelper(lead.id, first.helperId, 5000);
    assert.deepEqual([done.done, done.reply], [true, "echo: bir"]);
  });

  it("reports a helper still at work after the wait runs out", async () => {
    const lead = await create({ orchestrate: true });
    const helper = await sessions.startHelper(lead.id, { name: "Yavaş", task: "slow", agent: "fake" });
    const early = await sessions.waitForHelper(lead.id, helper.helperId, 20);
    assert.equal(early.done, false);
    const late = await sessions.waitForHelper(lead.id, helper.helperId, 5000);
    assert.deepEqual([late.done, late.reply], [true, "echo: slow"]);
  });

  it("recognises calls to its own tools by exact title only", () => {
    for (const title of ["mcp__kervan__start_helper", "kervan.wait_for_helper", "list_agents (kervan MCP Server)"]) {
      assert.ok(isOrchestraCall(title, "other"), title);
    }
    assert.ok(!isOrchestraCall("mcp__kervan__start_helper", "execute"));
    assert.ok(!isOrchestraCall("echo mcp__kervan__start_helper && touch x", "other"));
    assert.ok(!isOrchestraCall("mcp__github__list_agents", "other"));
    assert.ok(isOrchestraCall("mcp__kervan__helper_diff", "other"));
    assert.ok(!isOrchestraCall("mcp__kervan__merge_helper", "other"), "merging changes the lead's files, so the user is asked");
  });

  it("lets a lead call its tools without asking, but still asks for anything else", async () => {
    const lead = await create({ orchestrate: true });
    send(ws, { type: "session.prompt", id: "q1", sessionId: lead.id, text: "askperm: other mcp__kervan__list_helpers" });
    await answer(lead.id, /^permission: yes$/);
    assert.ok(!sessions.history(lead.id).some((e) => e.kind === "permission_request"), "no card for the user");

    send(ws, { type: "session.prompt", id: "q2", sessionId: lead.id, text: "askperm: execute mcp__kervan__list_helpers" });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === lead.id && m.session.status === "waiting");
    await sessions.cancel(lead.id);

    const plain = await create();
    send(ws, { type: "session.prompt", id: "q3", sessionId: plain.id, text: "askperm: other mcp__kervan__list_helpers" });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === plain.id && m.session.status === "waiting");
    await sessions.cancel(plain.id);
  });

  it("refuses tool calls without a lead's token", async () => {
    const status = await new Promise<number>((resolve, reject) => {
      const req = request({ socketPath: join(dataDir, "orchestra.sock"), path: "/tools", headers: { authorization: "Bearer nope" } }, (res) =>
        resolve(res.statusCode ?? 0),
      );
      req.on("error", reject);
      req.end();
    });
    assert.equal(status, 401);
  });

  it("starts team leads with the tools", async () => {
    send(ws, { type: "role.save", id: "r1", role: { id: "sef", name: "Şef", agent: "fake", lead: true } });
    send(ws, { type: "role.save", id: "r2", role: { id: "isci", name: "İşçi", agent: "fake" } });
    await inbox.waitFor((m) => m.type === "role.list.result" && m.id === "r2");
    send(ws, { type: "team.create", id: "t1", title: "Takım", roles: ["sef", "isci"] });
    const { team } = await inbox.waitFor((m) => m.type === "team.created" && m.id === "t1");
    const [chief, worker] = team.sessionIds.map((id: string) => sessions.list().find((s) => s.id === id)!);
    assert.deepEqual([chief.orchestrate, worker.orchestrate], [true, undefined]);

    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === chief.id && m.session.status === "idle");
    const helper = await sessions.startHelper(chief.id, { name: "Ek", task: "x", role: "isci" });
    const info = sessions.list().find((s) => s.id === helper.helperId)!;
    assert.deepEqual([info.teamId, info.role], [team.id, "İşçi"]);
  });
});

describe("splitting work and resting helpers", () => {
  /** Waits until the session's last turn has ended. */
  async function turnEnded(sessions: SessionManager, id: string, after = 0): Promise<void> {
    for (let i = 0; i < 200; i++) {
      const events = sessions.history(id);
      if (events.filter((e) => e.kind === "turn_end").length > after) return;
      await new Promise((r) => setTimeout(r, 25));
    }
    throw new Error(`no turn end for ${id}`);
  }

  it("rests an idle helper's agent, then picks it up again on the next message", async () => {
    const { sessions, stop } = await startServer({ limits: { helperIdleMinutes: 0.005 } });
    try {
      const lead = await sessions.create("fake", [], [], { orchestrate: true });
      const helper = await sessions.startHelper(lead.id, { name: "H", task: "selam", agent: "fake" });
      await sessions.waitForHelper(lead.id, helper.helperId, 5_000);
      for (let i = 0; i < 80 && !sessions.list().find((s) => s.id === helper.helperId)!.resting; i++) {
        await new Promise((r) => setTimeout(r, 25));
      }
      assert.equal(sessions.list().find((s) => s.id === helper.helperId)!.resting, true, "rested after sitting idle");
      assert.ok(sessions.history(helper.helperId).some((e) => e.kind === "notice" && /Resting/.test(e.text)));

      sessions.prompt(helper.helperId, "again", [], lead.id);
      await turnEnded(sessions, helper.helperId, 1);
      const info = sessions.list().find((s) => s.id === helper.helperId)!;
      assert.equal(info.resting, undefined, "woken by the message");
      const replies = sessions.history(helper.helperId).filter((e) => e.kind === "agent_message_chunk").map((e) => (e.kind === "agent_message_chunk" ? e.text : ""));
      assert.match(replies.join(""), /again/);
    } finally {
      await stop();
    }
  });

  it("stops and rests a lead's helpers when the lead is archived", async () => {
    const { sessions, stop } = await startServer({ limits: { helperIdleMinutes: 0 } });
    try {
      const lead = await sessions.create("fake", [], [], { orchestrate: true });
      const helper = await sessions.startHelper(lead.id, { name: "H", task: "selam", agent: "fake" });
      await sessions.waitForHelper(lead.id, helper.helperId, 5_000);
      assert.equal(sessions.list().find((s) => s.id === helper.helperId)!.resting, undefined, "resting is off here");
      await sessions.archive(lead.id, true);
      assert.equal(sessions.list().find((s) => s.id === helper.helperId)!.resting, true);
    } finally {
      await stop();
    }
  });

  it("tells a lead to judge the size and split only when asked to", async () => {
    const { sessions, stop } = await startServer();
    try {
      const split = await sessions.create("fake", [], [], { split: true });
      const plain = await sessions.create("fake", [], [], { orchestrate: true });
      assert.equal(sessions.list().find((s) => s.id === split.id)!.orchestrate, true, "splitting needs the helper tools");
      for (const s of [split, plain]) {
        await new Promise((r) => setTimeout(r, 300));
        sessions.prompt(s.id, "prefacecheck");
        await turnEnded(sessions, s.id);
      }
      const said = (id: string) => sessions.history(id).filter((e) => e.kind === "agent_message_chunk").map((e) => (e.kind === "agent_message_chunk" ? e.text : "")).join("");
      assert.match(said(split.id), /judge the size of the task/);
      assert.doesNotMatch(said(plain.id), /judge the size of the task/);
    } finally {
      await stop();
    }
  });
});

describe("orchestra socket path", () => {
  it("keeps a short path and moves a long one to a short name in the temp folder", () => {
    assert.equal(orchestraSocketPath("/var/lib/kervan/orchestra.sock"), "/var/lib/kervan/orchestra.sock");
    const long = `/${"d".repeat(200)}/orchestra.sock`;
    const short = orchestraSocketPath(long);
    assert.ok(Buffer.byteLength(short) <= 100, short);
    assert.equal(orchestraSocketPath(long), short, "the same data folder always gets the same socket");
  });
});
