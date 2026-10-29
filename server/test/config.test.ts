import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

describe("agent settings (model, effort, mode)", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;

  const ask = async (sessionId: string, text: string) => {
    const id = `p${++n}`;
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id, sessionId, text });
    const reply = await inbox.waitFor(
      (m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk",
      10_000,
    );
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");
    return reply.event.text as string;
  };

  const choose = async (sessionId: string, configId: string, value: string) => {
    const id = `s${++n}`;
    send(ws, { type: "session.config", id, sessionId, configId, value });
    return inbox.waitFor((m) => (m.type === "ok" || m.type === "error") && m.id === id);
  };

  before(async () => {
    let port = 0;
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

  it("offers the agent's choices, switches the model, and keeps the choice when the agent restarts", async () => {
    send(ws, { type: "session.create", id: "c1", agent: "fake" });
    const { session } = await inbox.waitFor((m) => m.type === "session.created" && m.id === "c1");
    const { session: ready } = await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.config);
    assert.deepEqual(ready.config, [
      {
        id: "model",
        name: "Model",
        category: "model",
        value: "fast",
        choices: [
          { value: "fast", name: "Hızlı" },
          { value: "smart", name: "Akıllı", description: "Daha yavaş" },
        ],
      },
    ], "groups flattened, the boolean option left out");
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle");

    assert.equal((await choose(session.id, "model", "smart")).type, "ok");
    assert.equal(await ask(session.id, "modelcheck"), "model: smart");
    assert.equal(sessions.list().find((s) => s.id === session.id)?.config?.[0].value, "smart");

    assert.match((await choose(session.id, "model", "huge")).message, /not one of the choices/);
    assert.match((await choose(session.id, "speed", "x")).message, /no setting 'speed'/);

    // The agent dies; the next message resumes it on its default model.
    send(ws, { type: "session.prompt", id: "crash", sessionId: session.id, text: "crash" });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === session.id && m.event.kind === "notice");
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle" && inbox.received.indexOf(m) > inbox.received.findIndex((x) => x.event?.kind === "notice"));
    assert.equal(await ask(session.id, "modelcheck"), "model: smart", "the choice is put back after the restart");
  });
});
