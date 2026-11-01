import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { isRunnable, isSignedIn, loadAgents, parseAgents } from "../src/agents.ts";

describe("agents.yaml", () => {
  it("resolves builtin adapters and keeps the file's order", () => {
    const agents = parseAgents(`
agents:
  gemini:
    command: builtin
  claude:
    name: Claude
    command: builtin
    env:
      ANTHROPIC_LOG: debug
`);
    assert.deepEqual(agents.ids, ["gemini", "claude"]);
    assert.equal(agents[0].name, "Gemini");
    assert.deepEqual(agents[0].args, ["--acp"]);
    assert.equal(agents[0].authMethod, "gemini-api-key", "builtin Gemini selects API-key auth");
    assert.ok(agents[0].command.endsWith("node_modules/.bin/gemini"));
    assert.equal(agents[1].name, "Claude");
    assert.deepEqual(agents[1].env, { ANTHROPIC_LOG: "debug" });
  });

  it("accepts a custom command", () => {
    const [agent] = parseAgents(`
agents:
  opencode:
    name: OpenCode
    command: opencode
    args: [acp]
`);
    assert.deepEqual(agent, { name: "OpenCode", command: "opencode", args: ["acp"] });
  });

  it("explains what is wrong", () => {
    assert.throws(() => parseAgents("agents: []", "x.yaml"), /x\.yaml: expected an 'agents:' map/);
    assert.throws(() => parseAgents("agents:\n  Bad Name: {command: x}"), /lowercase/);
    assert.throws(() => parseAgents("agents:\n  foo: {command: builtin}"), /no builtin adapter/);
    assert.throws(() => parseAgents("agents:\n  foo: {name: Foo}"), /needs a 'command'/);
    assert.throws(() => parseAgents("agents:\n  foo: {command: x, args: x}"), /'args' must be a list/);
    assert.throws(() => parseAgents("agents:\n  foo: {command: x, env: {A: 1}}"), /'env' must map/);
    assert.throws(() => parseAgents("agents:\n  foo: {command: x, authMethod: 3}"), /'authMethod' must be text/);
  });

  it("offers only agents that can run here", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-agents-"));
    const runnable = join(dir, "ok-agent");
    writeFileSync(runnable, "#!/bin/sh\n");
    chmodSync(runnable, 0o755);
    const file = join(dir, "agents.yaml");
    writeFileSync(file, `agents:\n  ok:\n    command: ${runnable}\n  missing:\n    command: ${join(dir, "nope")}\n`);

    assert.deepEqual([...loadAgents(file).keys()], ["ok"]);
    assert.equal(isRunnable("sh"), true, "bare names are looked up on PATH");
    assert.equal(isRunnable("definitely-not-a-command-kervan"), false);
  });

  it("falls back to the builtin adapters without a file", () => {
    assert.deepEqual([...loadAgents("/nonexistent/agents.yaml").keys()], ["claude", "codex", "gemini"]);
  });
});

describe("agent auth", () => {
  const start = async (authMethod?: string) => {
    const { LocalAcpRunner } = await import("../src/runner.ts");
    const { fakeAgent } = await import("./helpers.ts");
    const chunks: string[] = [];
    const agent = await new LocalAcpRunner().start({
      command: { ...fakeAgent, ...(authMethod ? { authMethod } : {}) },
      cwd: tmpdir(),
      onEvent: (event) => {
        if (event.kind === "agent_message_chunk") chunks.push(event.text);
      },
      onPermission: async () => null,
    });
    return { agent, chunks };
  };

  it("selects the configured auth method before the first prompt", async () => {
    const { agent, chunks } = await start("fake-key");
    await agent.prompt("authstate");
    assert.deepEqual(chunks, ["fake-key"]);
    agent.close();
  });

  it("skips authentication when none is configured", async () => {
    const { agent, chunks } = await start();
    await agent.prompt("authstate");
    assert.deepEqual(chunks, ["none"]);
    agent.close();
  });

  it("fails clearly when the agent doesn't offer the method", async () => {
    await assert.rejects(start("oauth-personal"), /does not offer auth method 'oauth-personal'/);
  });
});

describe("builtin agent sign-in", () => {
  const home = mkdtempSync(join(tmpdir(), "kervan-home-"));

  it("counts a key in the agent's env or the server's, and a saved login", () => {
    assert.equal(isSignedIn("claude", {}, {}, home, "linux"), false);
    assert.equal(isSignedIn("claude", { ANTHROPIC_API_KEY: "sk-ant-x" }, {}, home, "linux"), true);
    assert.equal(isSignedIn("codex", {}, { OPENAI_API_KEY: "sk-x" }, home, "linux"), true);
    assert.equal(isSignedIn("gemini", { GEMINI_API_KEY: "  " }, {}, home, "linux"), false, "a blank key is no key");
    mkdirSync(join(home, ".codex"));
    writeFileSync(join(home, ".codex/auth.json"), "{}");
    assert.equal(isSignedIn("codex", {}, {}, home, "linux"), true);
  });

  it("can't tell on a Mac, where logins live in the Keychain", () => {
    assert.equal(isSignedIn("claude", {}, {}, home, "darwin"), undefined);
    assert.equal(isSignedIn("claude", { ANTHROPIC_API_KEY: "sk-ant-x" }, {}, home, "darwin"), true);
  });

  it("says nothing about agents it doesn't know", () => {
    assert.equal(isSignedIn("yerel", {}, {}, home), undefined);
  });
});
