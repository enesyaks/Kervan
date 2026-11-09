import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { isMemoryCall } from "../src/orchestra.ts";
import { mapIndex, parseMap, readMap } from "../src/projectmemory.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const MAP = [
  "Here is the map.",
  "## @1 Overview — what it is",
  "A hub.",
  "## @1A Services — what each reaches",
  "Uses SQLite. See →1.",
  "### Detail",
  "## not an address",
].join("\n");

describe("project map sections", () => {
  it("splits a map at its hex addresses and leaves out what comes before them", () => {
    assert.deepEqual(parseMap(MAP).map((s) => s.id), ["1", "1a"]);
    assert.equal(mapIndex(MAP), "1 Overview — what it is\n1a Services — what each reaches");
    assert.doesNotMatch(mapIndex(MAP), /SQLite/);
  });

  it("addresses a map from before hex addresses by the position of its headings", () => {
    const old = "# Title\nOpening.\n## What it is\nA\n## Add a feature\nB";
    assert.deepEqual(parseMap(old).map((s) => [s.id, s.title]), [["0", "Introduction"], ["1", "What it is"], ["2", "Add a feature"]]);
  });

  it("reads sections by address in any case, and the index without ids", () => {
    assert.match(readMap(MAP, "1A"), /^## @1a Services[^]*Uses SQLite/);
    assert.doesNotMatch(readMap(MAP, "1a"), /A hub/);
    assert.match(readMap(MAP, "1, 1a"), /A hub[^]*Uses SQLite/);
    assert.equal(readMap(MAP), mapIndex(MAP));
    assert.throws(() => readMap(MAP, "ff"), /no map section 'ff'/);
  });

  it("hands over a map with no sections whole", () => {
    assert.deepEqual(parseMap("just text"), []);
    assert.equal(mapIndex("just text"), "");
    assert.equal(readMap("just text", "1"), "just text");
  });

  it("approves only the memory tools' exact titles", () => {
    assert.ok(isMemoryCall("mcp__kervan__map_read", "other"));
    assert.ok(isMemoryCall("case_read (kervan MCP Server)", "other"));
    assert.ok(!isMemoryCall("mcp__kervan__start_helper", "other"));
    assert.ok(!isMemoryCall("mcp__kervan__map_read", "execute"));
    assert.ok(!isMemoryCall("echo mcp__kervan__map_read", "other"));
  });
});

describe("project memory in a session", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  let projectId = "";
  let other = "";

  const create = async (extra: object) => {
    const id = `c${++n}`;
    send(ws, { type: "session.create", id, agent: "fake", ...extra });
    const { session } = await inbox.waitFor((m) => m.type === "session.created" && m.id === id);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle");
    return session;
  };
  const say = async (sessionId: string, text: string) => {
    const id = `p${++n}`;
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id, sessionId, text });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end" && inbox.received.indexOf(m) >= seen);
    return inbox.received
      .slice(seen)
      .filter((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk")
      .map((m) => m.event.text)
      .join("");
  };
  const makeProject = async (name: string) => {
    const id = `s${++n}`;
    send(ws, { type: "project.save", id, project: { name, path: mkdtempSync(join(tmpdir(), "kervan-memory-")) } });
    const { projects } = await inbox.waitFor((m) => m.type === "project.list.result" && m.id === id);
    return projects.find((p: any) => p.name === name).id as string;
  };

  before(async () => {
    let port = 0;
    ({ port, sessions, stop } = await startServer());
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    projectId = await makeProject("Hafıza");
    other = await makeProject("Başka");
    sessions.projects!.setMap(projectId, { status: "ready", agent: "fake", updatedAt: new Date().toISOString() }, MAP);
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("starts a session with the index, not the map, and reads sections on request", async () => {
    const session = await create({ projectId });
    const preface = await say(session.id, "prefacecheck");
    assert.match(preface, /1a Services — what each reaches/);
    assert.doesNotMatch(preface, /Uses SQLite/);
    assert.equal(await say(session.id, "mcptools"), "map_read,case_read");
    assert.match(await say(session.id, `memcall: map_read {"ids":"1a"}`), /Uses SQLite/);
    assert.match(await say(session.id, `memcall: start_helper {"name":"x","task":"y"}`), /refused: no tool named 'start_helper'/);
  });

  it("shows other sessions of the project in short, and none from elsewhere", async () => {
    const earlier = await create({ projectId });
    await say(earlier.id, "tarihsel-kelime nedir");
    const outside = await create({ projectId: other });
    await say(outside.id, "yabanci-kelime nedir");

    const reader = await create({ projectId });
    const short = earlier.id.replace(/-/g, "").slice(0, 4);
    const list = await say(reader.id, `memcall: case_read {}`);
    assert.match(list, new RegExp(`^${short}`, "m"));
    assert.ok(!list.includes(reader.id.replace(/-/g, "").slice(0, 8)));
    assert.ok(!list.includes(outside.id.replace(/-/g, "").slice(0, 4)));

    const detail = await say(reader.id, `memcall: case_read {"id":"${short}"}`);
    assert.match(detail, /asked: tarihsel-kelime nedir/);
    assert.match(detail, /result: /);
    assert.match(await say(reader.id, `memcall: case_read {"id":"${short}","full":true}`), /> tarihsel-kelime nedir/);
    assert.match(await say(reader.id, `memcall: case_read {"q":"tarihsel-kelime"}`), new RegExp(`^${short} `, "m"));
    assert.match(await say(reader.id, `memcall: case_read {"q":"yabanci-kelime"}`), /No matches/);
    assert.match(await say(reader.id, `memcall: case_read {"id":"${outside.id.slice(0, 8)}"}`), /refused: no session/);
  });

  it("gives no memory tools outside a project", async () => {
    const free = await create({});
    assert.equal(await say(free.id, "mcpcheck"), "mcp: ");
    assert.equal(await say(free.id, "prefacecheck"), "no preface");
  });

  it("gives a lead's helper the project's memory", async () => {
    const lead = await create({ projectId, orchestrate: true });
    const { helperId } = await sessions.startHelper(lead.id, { name: "Yardım", task: "mcptools", agent: "fake" });
    const summary = await sessions.waitForHelper(lead.id, helperId, 15_000);
    assert.equal(summary.reply, "map_read,case_read");
  });
});
