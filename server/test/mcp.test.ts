import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { McpRegistry } from "../src/mcp.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const github = {
  name: "github",
  transport: "stdio",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-github"],
  env: { GITHUB_TOKEN: "ghp_secret" },
};

describe("MCP registry", () => {
  const fresh = () => new McpRegistry(join(mkdtempSync(join(tmpdir(), "kervan-mcp-")), "mcp.json"));

  it("never shows secret values, and keeps them when an edit sends null", () => {
    const registry = fresh();
    assert.deepEqual(registry.save(github), {
      name: "github",
      transport: "stdio",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-github"],
      envKeys: ["GITHUB_TOKEN"],
      headerKeys: [],
    });
    registry.save({ ...github, args: [], env: { GITHUB_TOKEN: null, EXTRA: "1" } });
    const [server] = registry.toAcp(["github"], true).servers;
    assert.deepEqual(server, {
      name: "github",
      command: "npx",
      args: [],
      env: [
        { name: "GITHUB_TOKEN", value: "ghp_secret" },
        { name: "EXTRA", value: "1" },
      ],
    });
  });

  it("stores its file readable by the owner only and reloads it", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-mcp-"));
    const file = join(dir, "mcp.json");
    new McpRegistry(file).save(github);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(new McpRegistry(file).list()[0].name, "github");
    assert.match(readFileSync(file, "utf8"), /ghp_secret/);
  });

  it("validates input", () => {
    const registry = fresh();
    assert.throws(() => registry.save({ ...github, name: "Bad Name" }), /lowercase/);
    assert.throws(() => registry.save({ name: "x", transport: "stdio" }), /needs a command/);
    assert.throws(() => registry.save({ name: "x", transport: "http", url: "ftp://x" }), /http\(s\) url/);
    assert.throws(() => registry.save({ name: "x", transport: "carrier-pigeon" }), /transport/);
    assert.throws(() => registry.save({ ...github, name: "new", env: { TOKEN: null } }), /no stored value/);
  });

  it("drops HTTP servers for agents that can't use them", () => {
    const registry = fresh();
    registry.save({ name: "docs", transport: "http", url: "https://mcp.example.com", headers: { Authorization: "Bearer x" } });
    assert.deepEqual(registry.toAcp(["docs"], false), { servers: [], skipped: ["docs"] });
    assert.deepEqual(registry.toAcp(["docs"], true).servers, [
      { type: "http", name: "docs", url: "https://mcp.example.com", headers: [{ name: "Authorization", value: "Bearer x" }] },
    ]);
  });
});

describe("MCP over the socket", () => {
  let port = 0;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;

  before(async () => {
    ({ port, stop } = await startServer());
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

  it("saves, lists without secrets, and hands the server to the agent", async () => {
    send(ws, { type: "mcp.save", id: "s1", server: github });
    const saved = await inbox.waitFor((m) => m.type === "mcp.list.result" && m.id === "s1");
    assert.deepEqual(saved.servers[0].envKeys, ["GITHUB_TOKEN"]);
    assert.ok(!JSON.stringify(saved).includes("ghp_secret"), "secret never sent to the client");

    send(ws, { type: "session.create", id: "c1", agent: "fake", mcpServers: ["github"] });
    const { session } = await inbox.waitFor((m) => m.type === "session.created" && m.id === "c1");
    assert.deepEqual(session.mcpServers, ["github"]);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle");

    send(ws, { type: "session.prompt", id: "p1", sessionId: session.id, text: "mcpcheck" });
    const reply = await inbox.waitFor(
      (m) => m.type === "session.event" && m.sessionId === session.id && m.event.kind === "agent_message_chunk",
    );
    assert.equal(reply.event.text, "mcp: github");
  });

  it("refuses unknown servers and deletes", async () => {
    send(ws, { type: "session.create", id: "c2", agent: "fake", mcpServers: ["nope"] });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "c2")).message, /no MCP server named 'nope'/);
    send(ws, { type: "mcp.delete", id: "d1", name: "github" });
    assert.deepEqual((await inbox.waitFor((m) => m.type === "mcp.list.result" && m.id === "d1")).servers, []);
  });
});
