import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

describe("sessions", () => {
  let port = 0;
  let stop: () => Promise<void>;
  const sockets: WebSocket[] = [];
  let counter = 0;
  const nextId = () => `r${++counter}`;

  async function client(): Promise<{ ws: WebSocket; inbox: Inbox }> {
    const ws = openSocket(port);
    sockets.push(ws);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    return { ws, inbox };
  }

  async function idleSession(ws: WebSocket, inbox: Inbox): Promise<string> {
    const id = nextId();
    send(ws, { type: "session.create", id, agent: "fake" });
    const created = await inbox.waitFor((m) => m.type === "session.created" && m.id === id);
    const sessionId = created.session.id;
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");
    return sessionId;
  }

  const eventsOf = (inbox: Inbox, sessionId: string) =>
    inbox.received.filter((m) => m.type === "session.event" && m.sessionId === sessionId).map((m) => m.event);

  before(async () => {
    ({ port, stop } = await startServer());
  });

  after(async () => {
    for (const ws of sockets) ws.terminate();
    await stop();
  });

  it("advertises the available agents in welcome", async () => {
    const { inbox } = await client();
    assert.deepEqual((await inbox.waitFor((m) => m.type === "welcome")).agents, ["fake"]);
  });

  it("creates a session that becomes idle", async () => {
    const { ws, inbox } = await client();
    const id = nextId();
    send(ws, { type: "session.create", id, agent: "fake" });
    const created = await inbox.waitFor((m) => m.type === "session.created" && m.id === id);
    assert.equal(created.session.status, "starting");
    assert.equal(created.session.agent, "fake");
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === created.session.id && m.session.status === "idle");
  });

  it("rejects an unknown agent", async () => {
    const { ws, inbox } = await client();
    send(ws, { type: "session.create", id: "bad-agent", agent: "nope" });
    const error = await inbox.waitFor((m) => m.type === "error" && m.id === "bad-agent");
    assert.equal(error.code, "unknown_agent");
  });

  it("streams a prompt turn and titles the session", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    const id = nextId();
    send(ws, { type: "session.prompt", id, sessionId, text: "merhaba kervan" });

    await inbox.waitFor((m) => m.type === "ok" && m.id === id);
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");

    const events = eventsOf(inbox, sessionId);
    assert.deepEqual(
      events.map((e) => [e.kind, e.text ?? e.stopReason]),
      [
        ["user_message", "merhaba kervan"],
        ["agent_message_chunk", "echo: "],
        ["agent_message_chunk", "merhaba kervan"],
        ["turn_end", "end_turn"],
      ],
    );
    assert.deepEqual(events.map((e) => e.seq), [1, 2, 3, 4]);

    const running = await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "running");
    assert.equal(running.session.title, "merhaba kervan");
  });

  it("auto-rejects permission requests until approvals exist", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "use a tool" });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");

    const kinds = eventsOf(inbox, sessionId).map((e) => e.kind);
    assert.deepEqual(kinds.slice(3, 6), ["tool_call", "permission_auto_rejected", "tool_call_update"]);
    const update = eventsOf(inbox, sessionId).find((e) => e.kind === "tool_call_update");
    assert.equal(update.status, "failed");
  });

  it("refuses a second prompt while the agent is answering", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "slow" });
    const second = nextId();
    send(ws, { type: "session.prompt", id: second, sessionId, text: "again" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === second)).code, "session_busy");
  });

  it("keeps history for clients that connect later", async () => {
    const first = await client();
    const sessionId = await idleSession(first.ws, first.inbox);
    send(first.ws, { type: "session.prompt", id: nextId(), sessionId, text: "remember me" });
    await first.inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");

    const late = await client();
    const listId = nextId();
    send(late.ws, { type: "session.list", id: listId });
    const list = await late.inbox.waitFor((m) => m.type === "session.list.result" && m.id === listId);
    assert.ok(list.sessions.some((s: any) => s.id === sessionId));

    const historyId = nextId();
    send(late.ws, { type: "session.history", id: historyId, sessionId });
    const history = await late.inbox.waitFor((m) => m.type === "session.history.result" && m.id === historyId);
    assert.equal(history.events[0].text, "remember me");
    assert.equal(history.events.at(-1).kind, "turn_end");
  });

  it("marks the session as errored when the agent crashes", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "crash" });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "error");
  });

  it("reports unknown sessions", async () => {
    const { ws, inbox } = await client();
    send(ws, { type: "session.prompt", id: "ghost", sessionId: "nope", text: "hi" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === "ghost")).code, "unknown_session");
  });
});
