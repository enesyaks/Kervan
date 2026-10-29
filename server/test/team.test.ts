import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

describe("roles and teams", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;

  before(async () => {
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

  it("saves roles and checks what they refer to", async () => {
    send(ws, { type: "role.save", id: "r1", role: { id: "yazar", name: "Yazar", agent: "fake", instructions: "Kodu sen yazarsın." } });
    send(ws, { type: "role.save", id: "r2", role: { id: "inceleyici", name: "İnceleyici", agent: "fake", instructions: "Sadece incele, yazma." } });
    const { roles } = await inbox.waitFor((m) => m.type === "role.list.result" && m.id === "r2");
    assert.deepEqual(roles.map((r: any) => r.id), ["inceleyici", "yazar"]);

    send(ws, { type: "role.save", id: "r3", role: { id: "x", name: "X", agent: "nope" } });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "r3")).message, /no agent named 'nope'/);
    send(ws, { type: "role.save", id: "r4", role: { id: "x", name: "X", agent: "fake", skills: ["yok"] } });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "r4")).message, /no skill named 'yok'/);
  });

  it("creates a team whose members share a folder and get their role", async () => {
    send(ws, { type: "team.create", id: "t1", title: "Web sitesi", roles: ["yazar", "inceleyici"] });
    const { team } = await inbox.waitFor((m) => m.type === "team.created" && m.id === "t1");
    assert.equal(team.title, "Web sitesi");
    assert.equal(team.sessionIds.length, 2);

    const [writer, reviewer] = team.sessionIds.map((id: string) => sessions.list().find((s) => s.id === id)!);
    assert.deepEqual([writer.role, reviewer.role], ["Yazar", "İnceleyici"]);
    assert.deepEqual([writer.title, writer.teamId], ["Yazar", team.id]);
    assert.equal(sessions.workspace(writer.id), sessions.workspace(reviewer.id), "one shared folder");

    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === reviewer.id && m.session.status === "idle");
    send(ws, { type: "session.prompt", id: "p1", sessionId: reviewer.id, text: "prefacecheck" });
    const reply = await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === reviewer.id && m.event.kind === "agent_message_chunk",
    );
    assert.match(reply.event.text, /Your role in this team: İnceleyici\.\nSadece incele, yazma\./);
    assert.match(reply.event.text, /same folder/);

    send(ws, { type: "team.list", id: "l1" });
    const { teams } = await inbox.waitFor((m) => m.type === "team.list.result" && m.id === "l1");
    assert.deepEqual(teams.map((t: any) => t.sessionIds.length), [2]);
  });

  it("refuses unknown roles and empty teams", async () => {
    send(ws, { type: "team.create", id: "t2", title: "X", roles: ["yok"] });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "t2")).message, /no role named 'yok'/);
    send(ws, { type: "team.create", id: "t3", title: "X", roles: [] });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === "t3")).code, "bad_message");
  });
});
