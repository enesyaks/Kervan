import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { AcpRegistry, commandNames, ollamaURL, packageName, platformKey, type RegistryEntry } from "../src/agentregistry.ts";
import { fakeAgent, HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

describe("ACP registry helpers", () => {
  it("names platforms, packages and commands the registry's way", () => {
    assert.equal(platformKey("linux", "x64"), "linux-x86_64");
    assert.equal(platformKey("darwin", "arm64"), "darwin-aarch64");
    assert.equal(packageName("@qwen-code/qwen-code@0.26.5"), "@qwen-code/qwen-code");
    assert.equal(packageName("opencode-ai@1.0.0"), "opencode-ai");
    assert.equal(packageName("plain"), "plain");
    const qwen: RegistryEntry = { id: "qwen-code", name: "Qwen Code", distribution: { npx: { package: "@qwen-code/qwen-code@0.26.5" } } };
    assert.deepEqual(commandNames(qwen), ["qwen", "qwen-code"]);
    const goose: RegistryEntry = { id: "goose", name: "goose", distribution: { binary: { "linux-x86_64": { archive: "x", cmd: "./goose" } } } };
    assert.deepEqual(commandNames(goose, "linux-x86_64"), ["goose"]);
  });

  it("reads OLLAMA_HOST with or without a scheme and port", () => {
    assert.equal(ollamaURL(undefined), "http://127.0.0.1:11434");
    assert.equal(ollamaURL("0.0.0.0"), "http://0.0.0.0:11434");
    assert.equal(ollamaURL("http://gpu-box:8080"), "http://gpu-box:8080");
  });
});

describe("agents from the ACP registry", () => {
  const work = mkdtempSync(join(tmpdir(), "kervan-registry-"));
  const bin = join(work, "bin");
  const platform = platformKey();
  let files: Server;
  let base = "";
  const ollamaModels = ["qwen3-coder:30b"];
  const path = process.env.PATH;

  before(async () => {
    execFileSync("mkdir", ["-p", bin, join(work, "pack")]);
    // On PATH already: as if installed by hand.
    writeFileSync(join(bin, "found-agent"), "#!/bin/sh\necho found\n", { mode: 0o755 });
    writeFileSync(join(bin, "goose"), "#!/bin/sh\necho goose\n", { mode: 0o755 });
    // A downloadable agent: an archive holding a program that starts the test suite's ACP agent.
    writeFileSync(join(work, "pack", "fake-acp"), `#!/bin/sh\nexec "${fakeAgent.command}" "${fakeAgent.args[0]}"\n`, { mode: 0o755 });
    execFileSync("tar", ["-czf", join(work, "agent.tar.gz"), "-C", join(work, "pack"), "fake-acp"]);
    const archive = readFileSync(join(work, "agent.tar.gz"));
    const sum = createHash("sha256").update(archive).digest("hex");

    files = createServer((req, res) => {
      if (req.url === "/agent.tar.gz") return res.end(archive);
      if (req.url === "/api/tags") return res.end(JSON.stringify({ models: ollamaModels.map((name) => ({ name })) }));
      res.statusCode = 404;
      res.end();
    });
    await new Promise<void>((resolve) => files.listen(0, "127.0.0.1", resolve));
    base = `http://127.0.0.1:${(files.address() as AddressInfo).port}`;

    const download = (sha256?: string) => ({ [platform]: { archive: `${base}/agent.tar.gz`, cmd: "./fake-acp", args: ["--acp"], ...(sha256 ? { sha256 } : {}) } });
    const registry = {
      version: "1.0.0",
      agents: [
        { id: "claude-acp", name: "Claude Agent", distribution: { npx: { package: "@agentclientprotocol/claude-agent-acp@1" } } },
        { id: "found-agent", name: "Found", description: "Already on the server", distribution: { binary: { [platform]: { archive: "x", cmd: "./found-agent", args: ["acp"] } } } },
        { id: "downloadable", name: "Downloadable", distribution: { binary: download(sum) } },
        { id: "unsigned", name: "Unsigned", distribution: { binary: download() } },
        { id: "tampered", name: "Tampered", distribution: { binary: download("0".repeat(64)) } },
        { id: "goose", name: "goose", distribution: { binary: { [platform]: { archive: "x", cmd: "./goose", args: ["acp"] } } } },
      ],
    };
    writeFileSync(join(work, "registry.json"), JSON.stringify(registry));
    process.env.KERVAN_ACP_REGISTRY = join(work, "registry.json");
    process.env.OLLAMA_HOST = base;
    process.env.PATH = `${bin}:${path}`;
  });

  after(() => {
    files.close();
    process.env.PATH = path;
    delete process.env.KERVAN_ACP_REGISTRY;
    delete process.env.OLLAMA_HOST;
  });

  it("says where each agent stands on this server", async () => {
    const registry = new AcpRegistry(join(work, "tools-a"));
    const offered = await registry.offer(new Set(["claude", "goose"]));
    const by = Object.fromEntries(offered.map((agent) => [agent.id, agent]));
    assert.equal(by["claude-acp"].status, "builtin");
    assert.equal(by["found-agent"].status, "found");
    assert.equal(by["found-agent"].path, join(bin, "found-agent"));
    assert.equal(by.downloadable.status, "installable");
    assert.equal(by.downloadable.source, "download");
    assert.equal(by.unsigned.status, "unavailable");
    assert.match(by.unsigned.reason ?? "", /checksum/);
    assert.equal(by.goose.status, "added");
    assert.equal(by.goose.ollama, true);
    assert.equal(offered[0].status, "found", "what's on the server comes first");
  });

  it("uses an agent found on the server where it is", async () => {
    const installed = await new AcpRegistry(join(work, "tools-b")).install({ agentId: "found-agent" });
    assert.deepEqual(installed, { id: "found-agent", name: "Found", command: join(bin, "found-agent"), args: ["acp"] });
  });

  it("downloads an agent, checks its checksum and unpacks it under tools/", async () => {
    const tools = join(work, "tools-c");
    const installed = await new AcpRegistry(tools).install({ agentId: "downloadable" });
    assert.equal(installed.command, join(tools, "downloadable", "fake-acp"));
    assert.deepEqual(installed.args, ["--acp"]);
    await assert.rejects(new AcpRegistry(tools).install({ agentId: "tampered" }), /doesn't match the checksum/);
    await assert.rejects(new AcpRegistry(tools).install({ agentId: "unsigned" }), /no published checksum/);
    await assert.rejects(new AcpRegistry(tools).install({ agentId: "claude-acp" }), /comes with Kervan/);
  });

  it("points an agent at a model from the server's Ollama", async () => {
    const registry = new AcpRegistry(join(work, "tools-d"));
    const status = await registry.ollama();
    assert.deepEqual(status, { running: true, url: base, models: ["qwen3-coder:30b"] });
    const installed = await registry.install({ agentId: "goose", ollamaModel: "qwen3-coder:30b" });
    assert.equal(installed.name, "goose (qwen3-coder:30b)");
    assert.deepEqual(installed.env, { GOOSE_PROVIDER: "ollama", GOOSE_MODEL: "qwen3-coder:30b", OLLAMA_HOST: base });
    await assert.rejects(registry.install({ agentId: "goose", ollamaModel: "missing:7b" }), /no model 'missing:7b'/);
    await assert.rejects(registry.install({ agentId: "found-agent", ollamaModel: "qwen3-coder:30b" }), /can't be set up for Ollama/);
  });

  it("installs and adds an agent from the app, which then lists it", async () => {
    const server = await startServer();
    try {
      const ws = openSocket(server.port);
      const inbox = new Inbox(ws);
      await opened(ws);
      send(ws, HELLO);
      await inbox.waitFor((m) => m.type === "welcome");
      send(ws, { type: "agent.registry", id: "r1" });
      const listing = await inbox.waitFor((m) => m.id === "r1");
      assert.equal(listing.type, "agent.registry.result", JSON.stringify(listing));
      assert.equal(listing.ollama.running, true);
      assert.ok(listing.agents.some((agent: { id: string; status: string }) => agent.id === "downloadable" && agent.status === "installable"));

      send(ws, { type: "agent.install", id: "i1", agentId: "downloadable" });
      const result = await inbox.waitFor((m) => m.id === "i1", 30_000);
      assert.equal(result.type, "agent.list.result", JSON.stringify(result));
      const added = result.agents.find((agent: { id: string }) => agent.id === "downloadable");
      assert.ok(added, "the installed agent is in the server's list");
      assert.equal(added.source, "app");
      assert.ok(added.command.startsWith(join(server.dataDir, "tools", "downloadable")), added.command);
      ws.close();
    } finally {
      await server.stop();
    }
  });
});
