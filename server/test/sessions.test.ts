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

    // The agent's slash commands may arrive at any point; they aren't part of the turn.
    const events = eventsOf(inbox, sessionId).filter((e) => e.kind !== "commands");
    assert.deepEqual(
      events.map((e) => [e.kind, e.text ?? e.stopReason ?? e.messageSeq]),
      [
        ["user_message", "merhaba kervan"],
        // The folder as it was before the message, for the Changes panel and rewinding.
        ["checkpoint", events[0].seq],
        ["agent_message_chunk", "echo: "],
        ["agent_message_chunk", "merhaba kervan"],
        ["turn_end", "end_turn"],
      ],
    );
    const seqs = events.map((e) => e.seq);
    assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b));
    assert.equal(events[1].messageSeq, events[0].seq);

    const running = await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "running");
    assert.equal(running.session.title, "merhaba kervan");
  });

  async function pendingPermission(ws: WebSocket, inbox: Inbox): Promise<{ sessionId: string; request: any }> {
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "use a tool" });
    const { event } = await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_request",
    );
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "waiting");
    return { sessionId, request: event };
  }

  const toolStatus = async (inbox: Inbox, sessionId: string) =>
    (
      await inbox.waitFor(
        (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "tool_call_update",
      )
    ).event.status;

  it("holds a permission request until the user allows it", async () => {
    const { ws, inbox } = await client();
    const { sessionId, request } = await pendingPermission(ws, inbox);
    assert.equal(request.title, "Edit README.md");
    assert.equal(request.toolKind, "edit");
    assert.equal(request.detail, "sed -i s/a/b/ README.md");
    assert.deepEqual(request.options.map((o: any) => o.kind), ["allow_once", "reject_once"]);

    const id = nextId();
    send(ws, { type: "session.permission", id, sessionId, requestId: request.requestId, optionId: "yes" });
    await inbox.waitFor((m) => m.type === "ok" && m.id === id);

    assert.equal(await toolStatus(inbox, sessionId), "completed");
    const resolved = eventsOf(inbox, sessionId).find((e) => e.kind === "permission_resolved");
    assert.deepEqual([resolved.requestId, resolved.outcome, resolved.optionId], [request.requestId, "selected", "yes"]);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");
  });

  it("passes a rejection to the agent", async () => {
    const { ws, inbox } = await client();
    const { sessionId, request } = await pendingPermission(ws, inbox);
    send(ws, { type: "session.permission", id: nextId(), sessionId, requestId: request.requestId, optionId: "no" });
    assert.equal(await toolStatus(inbox, sessionId), "failed");
  });

  it("shows a pending request to a client that connects later", async () => {
    const first = await client();
    const { sessionId, request } = await pendingPermission(first.ws, first.inbox);

    const late = await client();
    const historyId = nextId();
    send(late.ws, { type: "session.history", id: historyId, sessionId });
    const history = await late.inbox.waitFor((m) => m.type === "session.history.result" && m.id === historyId);
    assert.equal(history.events.at(-1).requestId, request.requestId);

    send(late.ws, { type: "session.permission", id: nextId(), sessionId, requestId: request.requestId, optionId: "yes" });
    assert.equal(await toolStatus(first.inbox, sessionId), "completed");
  });

  it("cancels open requests when the turn is cancelled", async () => {
    const { ws, inbox } = await client();
    const { sessionId, request } = await pendingPermission(ws, inbox);
    send(ws, { type: "session.cancel", id: nextId(), sessionId });
    const { event } = await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "permission_resolved",
    );
    assert.deepEqual([event.requestId, event.outcome], [request.requestId, "cancelled"]);
    assert.equal(await toolStatus(inbox, sessionId), "failed");
  });

  it("rejects options the agent did not offer and unknown requests", async () => {
    const { ws, inbox } = await client();
    const { sessionId, request } = await pendingPermission(ws, inbox);

    const busy = nextId();
    send(ws, { type: "session.prompt", id: busy, sessionId, text: "another" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === busy)).code, "session_busy");

    const bogus = nextId();
    send(ws, { type: "session.permission", id: bogus, sessionId, requestId: request.requestId, optionId: "maybe" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === bogus)).code, "bad_message");

    const unknown = nextId();
    send(ws, { type: "session.permission", id: unknown, sessionId, requestId: "nope", optionId: "yes" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === unknown)).code, "unknown_request");
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

  it("restarts a crashed agent where it left off on the next message", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "whoami" });
    const before = await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk");

    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "crash" });
    await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "notice" && /restarts where it left off/.test(m.event.text),
    );
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");

    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "whoami" });
    const after = await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk" && m.event.seq > before.event.seq,
    );
    assert.equal(after.event.text, before.event.text, "the same agent conversation, resumed");
  });

  it("reports unknown sessions", async () => {
    const { ws, inbox } = await client();
    send(ws, { type: "session.prompt", id: "ghost", sessionId: "nope", text: "hi" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === "ghost")).code, "unknown_session");
  });

  it("renames, archives and finds sessions", async () => {
    const { ws, inbox } = await client();
    const sessionId = await idleSession(ws, inbox);
    send(ws, { type: "session.prompt", id: nextId(), sessionId, text: "karavan rotası" });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");

    send(ws, { type: "session.rename", id: nextId(), sessionId, title: "  İpek Yolu  " });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.title === "İpek Yolu");

    send(ws, { type: "session.archive", id: nextId(), sessionId, archived: true });
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.archived === true);

    const searchId = nextId();
    send(ws, { type: "session.search", id: searchId, query: "rotasi" });
    const { hits } = await inbox.waitFor((m) => m.type === "session.search.result" && m.id === searchId);
    assert.deepEqual(
      hits.filter((h: any) => h.sessionId === sessionId).map((h: any) => h.role).sort(),
      ["agent", "user"],
      "the prompt and the agent's echo of it",
    );

    const bad = nextId();
    send(ws, { type: "session.archive", id: bad, sessionId, archived: "yes" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === bad)).code, "bad_message");
  });
});

