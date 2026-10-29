import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { isRunnable, loadAgents, parseAgents } from "../src/agents.ts";

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
