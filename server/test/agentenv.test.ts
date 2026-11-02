import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { agentEnv, cleanEnv } from "../src/agentenv.ts";
import { envPrelude } from "../src/agentuser.ts";
import { parseAgents } from "../src/agents.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer, TEST_TOKEN } from "./helpers.ts";

describe("what an agent sees of the server's environment", () => {
  const server = { PATH: "/bin", HOME: "/home/k", LC_ALL: "tr_TR.UTF-8", KERVAN_TOKEN: "app-key", KERVAN_NODE_TOKEN: "node-key", OPENAI_API_KEY: "o", ANTHROPIC_API_KEY: "a", SOMETHING_NEW: "x" };

  it("passes only what's allowed", () => {
    assert.deepEqual(cleanEnv([], server), { PATH: "/bin", HOME: "/home/k", LC_ALL: "tr_TR.UTF-8" });
  });

  it("gives each agent the names it inherits, and its own settings on top", () => {
    const env = agentEnv({ inheritEnv: ["ANTHROPIC_*"], env: { MINE: "1", HOME: "/elsewhere" } }, server);
    assert.deepEqual(env, { PATH: "/bin", HOME: "/elsewhere", LC_ALL: "tr_TR.UTF-8", ANTHROPIC_API_KEY: "a", MINE: "1" });
    assert.deepEqual(cleanEnv(["SOMETHING_NEW"], server).SOMETHING_NEW, "x", "an exact name works too");
  });

  it("gives builtin agents their own keys and not each other's", () => {
    const agents = parseAgents("agents:\n  claude: { command: builtin }\n  codex: { command: builtin }\n  gemini: { command: builtin }\n", "test");
    const [claude, codex, gemini] = agents.map((agent) => agentEnv(agent, { ...server, GEMINI_API_KEY: "g", CLAUDE_CODE_OAUTH_TOKEN: "t" }));
    assert.equal(claude.ANTHROPIC_API_KEY, "a");
    assert.equal(claude.CLAUDE_CODE_OAUTH_TOKEN, "t");
    assert.equal(claude.OPENAI_API_KEY, undefined);
    assert.equal(codex.OPENAI_API_KEY, "o");
    assert.equal(codex.ANTHROPIC_API_KEY, undefined);
    assert.equal(gemini.GEMINI_API_KEY, "g");
    assert.equal(gemini.OPENAI_API_KEY, undefined);
    for (const env of [claude, codex, gemini]) assert.equal(env.KERVAN_TOKEN, undefined);
  });

  it("lets agents.yaml name more, and refuses a bad name", () => {
    const [agent] = parseAgents("agents:\n  mine: { command: mine, inheritEnv: [AWS_*, MY_KEY] }\n", "test");
    assert.deepEqual(agent.inheritEnv, ["AWS_*", "MY_KEY"]);
    assert.throws(() => parseAgents("agents:\n  mine: { command: mine, inheritEnv: ['A B'] }\n", "test"), /inheritEnv/);
  });
});

describe("handing the environment to bin/run-agent", () => {
  it("writes a count and base64 values, so nothing can break a line or reach ps", () => {
    const prelude = envPrelude({ A: "one two", B: "line\nbreak", "not-a-name": "x", GONE: undefined });
    assert.equal(prelude, `2\nA=${Buffer.from("one two").toString("base64")}\nB=${Buffer.from("line\nbreak").toString("base64")}\n`);
  });
});

describe("through a running server", () => {
  let port = 0;
  let stop: () => Promise<void>;
  const saved = { token: process.env.KERVAN_TOKEN, key: process.env.OPENAI_API_KEY };

  before(async () => {
    process.env.KERVAN_TOKEN = TEST_TOKEN;
    process.env.OPENAI_API_KEY = "OPENAI-SENTINEL";
    ({ port, stop } = await startServer());
  });
  after(async () => {
    await stop();
    if (saved.token === undefined) delete process.env.KERVAN_TOKEN;
    else process.env.KERVAN_TOKEN = saved.token;
    if (saved.key === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = saved.key;
  });

  async function client() {
    const ws = openSocket(port);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    let n = 0;
    const ask = (message: Record<string, unknown>) => {
      const id = `e${++n}`;
      send(ws, { ...message, id });
      return inbox.waitFor((m) => m.id === id, 15_000);
    };
    return { ws, inbox, ask };
  }

  const probe = `echo "SEEN token=[$KERVAN_TOKEN] key=[$OPENAI_API_KEY] home=[\${HOME:+set}]"`;

  it("keeps the app's key and API keys from an agent's commands", async () => {
    const { ws, inbox, ask } = await client();
    const saved = await ask({ type: "agent.save", agent: { id: "shell", name: "Shell", command: "/bin/sh", args: ["-i"], protocol: "pty", quietMs: 400 } });
    assert.equal(saved.type, "agent.list.result", JSON.stringify(saved));
    const created = await ask({ type: "session.create", agent: "shell" });
    const sessionId = created.session.id;
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);
    await ask({ type: "session.prompt", sessionId, text: probe });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk" && /SEEN token=\[\] key=\[\] home=\[set\]/.test(m.event.text), 15_000);
    ws.close();
  });

  it("keeps them from a terminal in a session's folder", async () => {
    const { ws, inbox, ask } = await client();
    const created = await ask({ type: "session.create", agent: "fake" });
    const sessionId = created.session.id;
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle", 15_000);
    const terminal = await ask({ type: "terminal.open", sessionId });
    send(ws, { type: "terminal.input", id: "ti", terminalId: terminal.terminalId, data: `${probe}\n` });
    await inbox.waitFor((m) => m.type === "terminal.output" && /SEEN token=\[\] key=\[\] home=\[set\]/.test(m.data), 10_000);
    ws.close();
  });
});
