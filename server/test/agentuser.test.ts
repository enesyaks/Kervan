import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { agentHasFile, agentUser, probeFolder, runAsAgent, spawnAgent } from "../src/agentuser.ts";

// A stand-in for sudo, first on PATH: it records what it was given. sudo drops the environment, so its paths are written in.
describe("reaching the agent user through sudo", () => {
  const saved = { PATH: process.env.PATH, user: process.env.KERVAN_AGENT_USER, token: process.env.KERVAN_TOKEN, workspaces: process.env.KERVAN_WORKSPACES_DIR };
  let bin: string;
  const recorded = (name: string) => readFileSync(join(bin, name), "utf8");
  const failNext = () => writeFileSync(join(bin, "fail"), "");
  const decodedPrelude = () => {
    const [count, ...lines] = recorded("stdin").trimEnd().split("\n");
    return { count: Number(count), env: Object.fromEntries(lines.map((line) => [line.split("=")[0], Buffer.from(line.split("=")[1], "base64").toString()])) };
  };

  before(() => {
    bin = mkdtempSync(join(tmpdir(), "kervan-fake-sudo-"));
    writeFileSync(
      join(bin, "sudo"),
      `#!/bin/sh\nprintf '%s\\n' "$@" > "${bin}/args"\n/usr/bin/env > "${bin}/env"\n/bin/pwd > "${bin}/cwd"\n/bin/cat > "${bin}/stdin"\necho out\necho err >&2\nif [ -e "${bin}/fail" ]; then exit 3; fi\n`,
    );
    chmodSync(join(bin, "sudo"), 0o755);
  });
  after(() => rmSync(bin, { recursive: true, force: true }));
  beforeEach(() => {
    rmSync(join(bin, "fail"), { force: true });
    process.env.PATH = `${bin}:${saved.PATH}`;
    process.env.KERVAN_AGENT_USER = "kervan-agent";
    process.env.KERVAN_TOKEN = "server-secret";
  });
  afterEach(() => {
    process.env.PATH = saved.PATH;
    for (const [name, value] of [["KERVAN_AGENT_USER", saved.user], ["KERVAN_TOKEN", saved.token], ["KERVAN_WORKSPACES_DIR", saved.workspaces]] as const) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  const exited = (child: ReturnType<typeof spawnAgent>) => new Promise<number | null>((resolve) => child.on("close", resolve));

  it("takes an empty KERVAN_AGENT_USER as no agent user", () => {
    process.env.KERVAN_AGENT_USER = "";
    assert.equal(agentUser(), undefined);
  });

  it("spawns through sudo without a password prompt, through the wrapper, with the program's arguments intact", async () => {
    const child = spawnAgent("/bin/tool", ["--flag", "two words"], { env: { PATH: "/x" }, cwd: bin });
    child.stdin.end();
    assert.equal(await exited(child), 0);
    const args = recorded("args").trimEnd().split("\n");
    assert.deepEqual(args.slice(0, 3), ["-n", "-u", "kervan-agent"]);
    assert.ok(args[3].endsWith("/bin/run-agent"), args[3]);
    assert.deepEqual(args.slice(4), ["/bin/tool", "--flag", "two words"]);
  });

  it("keeps the server's secrets out of sudo's environment and arguments, and gives the agent's only on stdin", async () => {
    const child = spawnAgent("/bin/tool", [], { env: { API_KEY: "agent-key" } });
    child.stdin.end("after the prelude");
    await exited(child);
    const env = recorded("env");
    assert.ok(!env.includes("server-secret"), "the server's key");
    assert.ok(!env.includes("KERVAN_"), "any Kervan setting");
    assert.ok(!env.includes("agent-key"), "the agent's key isn't in sudo's environment");
    assert.ok(!recorded("args").includes("agent-key"), "nor where ps shows it");
    assert.ok(recorded("stdin").startsWith(`1\nAPI_KEY=${Buffer.from("agent-key").toString("base64")}\n`));
    assert.ok(recorded("stdin").endsWith("after the prelude"), "the program's own stdin follows");
  });

  it("spawns directly when there is no agent user", async () => {
    delete process.env.KERVAN_AGENT_USER;
    const child = spawnAgent("/bin/echo", ["direct"], { env: {} });
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stdin.end();
    await exited(child);
    assert.equal(output, "direct\n");
  });

  it("runs a program as the agent and answers with its output", async () => {
    const result = await runAsAgent("git", ["status"], { env: { GIT_DIR: "/g" }, cwd: bin, timeout: 5000 });
    assert.deepEqual(result, { stdout: "out\n", stderr: "err\n" });
    assert.deepEqual(recorded("args").trimEnd().split("\n").slice(4), ["git", "status"]);
    assert.equal(decodedPrelude().env.GIT_DIR, "/g");
    assert.equal(statSync(recorded("cwd").trim()).ino, statSync(bin).ino, "in the folder asked for");
  });

  it("rejects with the program's output when it fails", async () => {
    failNext();
    await assert.rejects(runAsAgent("git", [], { env: {} }), (error: Error & { stdout?: string; stderr?: string; code?: number }) => {
      assert.equal(error.code, 3);
      assert.equal(error.stdout, "out\n");
      assert.equal(error.stderr, "err\n");
      return true;
    });
  });

  it("refuses to run as the agent when there is no agent user", () => {
    delete process.env.KERVAN_AGENT_USER;
    assert.throws(() => runAsAgent("git", [], { env: {} }), /no agent user/);
  });

  it("passes a looked-for path as an argument, not as shell text", () => {
    const hostile = "x; touch /tmp/kervan-pwned";
    assert.equal(agentHasFile(hostile), true);
    const args = recorded("args").trimEnd().split("\n");
    assert.deepEqual(args.slice(4), ["bash", "-c", 'test -e "$HOME/$1"', "_", hostile]);
    assert.deepEqual(Object.keys(decodedPrelude().env), ["PATH"], "only PATH goes along");
  });

  it("says a file isn't there when the check fails, or there's no agent user to ask", () => {
    failNext();
    assert.equal(agentHasFile(".claude.json"), false);
    delete process.env.KERVAN_AGENT_USER;
    assert.equal(agentHasFile(".claude.json"), false);
  });

  it("makes a probe folder the agent user can write to, among the workspaces", () => {
    const workspaces = mkdtempSync(join(tmpdir(), "kervan-workspaces-"));
    const umask = process.umask(0o002); // the service's, from infra/kervan.service
    try {
      process.env.KERVAN_WORKSPACES_DIR = workspaces;
      const folder = probeFolder();
      assert.equal(dirname(folder), workspaces);
      assert.equal(statSync(folder).mode & 0o070, 0o070, "group-writable");
      assert.equal(statSync(folder).mode & 0o007, 0, "nobody else's");
    } finally {
      process.umask(umask);
      rmSync(workspaces, { recursive: true, force: true });
    }
  });

  it("makes a private temporary probe folder without an agent user", () => {
    delete process.env.KERVAN_AGENT_USER;
    const folder = probeFolder();
    try {
      assert.ok(existsSync(folder));
      assert.equal(statSync(folder).mode & 0o077, 0);
    } finally {
      rmSync(folder, { recursive: true, force: true });
    }
  });
});
