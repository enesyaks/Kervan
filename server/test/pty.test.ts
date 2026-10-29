import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";
import { parseAgents } from "../src/agents.ts";
import { EventStore } from "../src/store.ts";
import { stripAnsi } from "../src/pty.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import { SessionManager } from "../src/sessions.ts";

const terminal = {
  name: "Terminal",
  command: process.execPath,
  args: [join(import.meta.dirname, "fixtures/fake-terminal.ts")],
  protocol: "pty" as const,
  quietMs: 400,
};

const open: SessionManager[] = [];
const manager = () => {
  const sessions = new SessionManager(new LocalAcpRunner(), new Map([["term", terminal]]), mkdtempSync(join(tmpdir(), "kervan-pty-")), new EventStore(":memory:"));
  open.push(sessions);
  return sessions;
};

const until = async (check: () => boolean, ms = 8000) => {
  const deadline = Date.now() + ms;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
};

const answers = (sessions: SessionManager, id: string) =>
  sessions
    .history(id)
    .flatMap((e) => (e.kind === "agent_message_chunk" ? [e.text] : []))
    .join("");

describe("PTY fallback for agents without ACP", () => {
  // Terminal agents are child processes; close them even when a test fails, or the run never ends.
  after(() => {
    for (const sessions of open) sessions.closeAll();
  });

  it("strips colours, titles and carriage returns", () => {
    assert.equal(stripAnsi("\x1b]0;başlık\x07\x1b[1;32mtamam\x1b[0m\r\n"), "tamam\n");
  });

  it("reads protocol and quiet time from agents.yaml", () => {
    const [agent] = parseAgents("agents:\n  aider:\n    command: aider\n    protocol: pty\n    quietMs: 1500\n");
    assert.deepEqual([agent.protocol, agent.quietMs], ["pty", 1500]);
    assert.throws(() => parseAgents("agents:\n  x:\n    command: x\n    protocol: telnet\n"), /'acp' or 'pty'/);
  });

  it("types each message as a line and ends the turn once the agent goes quiet", async () => {
    const sessions = manager();
    const { id } = await sessions.create("term");
    await until(() => sessions.list()[0].status === "idle");
    assert.deepEqual(sessions.agentDetails, [{ id: "term", name: "Terminal", terminal: true }]);

    sessions.prompt(id, "yavaş");
    await until(() => sessions.history(id).some((e) => e.kind === "turn_end"));
    const text = answers(sessions, id);
    assert.match(text, /cevap: yavaş\n/, "both halves of the answer, across the pause");
    assert.ok(!text.includes("\x1b"), "no control sequences");
    assert.equal(text.match(/yavaş/g)?.length, 1, "the typed line isn't echoed back as part of the answer");
    sessions.closeAll();
  });

  it("refuses to make a terminal agent a lead", async () => {
    const sessions = manager();
    sessions.useOrchestra({ mcpServer: () => ({ name: "kervan", command: "x", args: [], env: [] }) });
    await assert.rejects(sessions.create("term", [], [], { orchestrate: true }), /terminal agents/);
  });

  it("starts a fresh terminal after the agent exits, and says it forgot", async () => {
    const sessions = manager();
    const { id } = await sessions.create("term");
    await until(() => sessions.list()[0].status === "idle");
    sessions.prompt(id, "çık");
    await until(() => sessions.history(id).some((e) => e.kind === "notice"));
    await until(() => sessions.list()[0].status === "idle");

    sessions.prompt(id, "tekrar");
    await until(() => sessions.history(id).filter((e) => e.kind === "turn_end").length >= 1);
    const notices = sessions.history(id).flatMap((e) => (e.kind === "notice" ? [e.text] : []));
    assert.ok(notices.some((t) => /hatırlamaz/.test(t)));
    assert.match(answers(sessions, id), /cevap: tekrar/);
    sessions.closeAll();
  });
});
