import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { AgentCatalog } from "../src/catalog.ts";
import { LocalAcpRunner, probeAgent } from "../src/runner.ts";
import { HELLO, Inbox, fakeAgent, openSocket, opened, send, startServer } from "./helpers.ts";

const runner = new LocalAcpRunner();
const fresh = () => {
  const file = join(mkdtempSync(join(tmpdir(), "kervan-catalog-")), "agents.json");
  const base = new Map([["claude", { name: "Claude Code", command: process.execPath, args: [] }]]);
  return { file, base, catalog: new AgentCatalog(file, base, (d) => probeAgent(runner, d, 10_000)) };
};
const custom = { id: "yerel", name: "Yerel ajan", command: process.execPath, args: fakeAgent.args, env: { API_KEY: "s3cret" } };

describe("agent catalog", () => {
  it("adds a working agent after trying it, without exposing secrets", async () => {
    const { file, base, catalog } = fresh();
    await catalog.save(custom);
    assert.ok(catalog.live.has("yerel"), "available to new sessions at once");
    assert.equal(catalog.live.get("yerel")?.env?.API_KEY, "s3cret");

    const listed = catalog.list().find((a) => a.id === "yerel");
    assert.deepEqual([listed?.source, listed?.node, listed?.envKeys, listed?.available], ["app", "local", ["API_KEY"], true]);
    assert.ok(!JSON.stringify(catalog.list()).includes("s3cret"));
    assert.equal(statSync(file).mode & 0o777, 0o600);

    const reloaded = new AgentCatalog(file, base, async () => {});
    assert.equal(reloaded.live.get("yerel")?.name, "Yerel ajan");
  });

  it("keeps a stored secret when an edit sends null", async () => {
    const { catalog } = fresh();
    await catalog.save(custom);
    await catalog.save({ ...custom, name: "Yeni ad", env: { API_KEY: null } });
    assert.equal(catalog.live.get("yerel")?.env?.API_KEY, "s3cret");
    assert.equal(catalog.live.get("yerel")?.name, "Yeni ad");
  });

  it("refuses agents that don't start, bad ids and unknown nodes", async () => {
    const { catalog } = fresh();
    await assert.rejects(catalog.save({ id: "bozuk", command: "sh", args: ["-c", "exit 1"] }), /didn't start/);
    await assert.rejects(catalog.save({ ...custom, id: "Kötü Ad" }), /lowercase/);
    await assert.rejects(catalog.save({ ...custom, node: "gpu-box" }), /node 'gpu-box' is not available/);
    await assert.rejects(catalog.save({ ...custom, command: "definitely-not-a-command-kervan" }), /can't be run/);
    assert.ok(!catalog.live.has("bozuk"));
  });

  it("removes only agents added from the app", async () => {
    const { catalog } = fresh();
    await catalog.save(custom);
    catalog.remove("yerel");
    assert.ok(!catalog.live.has("yerel"));
    assert.throws(() => catalog.remove("claude"), /not added from the app/);
  });
});

describe("agents over the socket", () => {
  let port = 0;
  let stop: () => Promise<void>;
  const sockets: WebSocket[] = [];

  const client = async () => {
    const ws = openSocket(port);
    sockets.push(ws);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    return { ws, inbox };
  };

  before(async () => {
    ({ port, stop } = await startServer());
  });

  after(async () => {
    for (const ws of sockets) ws.terminate();
    await stop();
  });

  it("saves an agent and tells every connected app", async () => {
    const editor = await client();
    const other = await client();

    send(editor.ws, { type: "agent.save", id: "a1", agent: custom });
    const result = await editor.inbox.waitFor((m) => m.type === "agent.list.result" && m.id === "a1", 15_000);
    assert.deepEqual(result.nodes, ["local"]);
    assert.ok(result.agents.some((a: any) => a.id === "yerel" && a.source === "app"));

    const update = await other.inbox.waitFor((m) => m.type === "agents.updated");
    assert.deepEqual(update.agentDetails.map((a: any) => a.id), ["fake", "yerel"]);

    send(editor.ws, { type: "session.create", id: "c1", agent: "yerel" });
    await editor.inbox.waitFor((m) => m.type === "session.created" && m.id === "c1");
  });

  it("reports why an agent was refused", async () => {
    const { ws, inbox } = await client();
    send(ws, { type: "agent.save", id: "a2", agent: { id: "bozuk", command: "sh", args: ["-c", "exit 1"] } });
    const error = await inbox.waitFor((m) => m.type === "error" && m.id === "a2", 15_000);
    assert.match(error.message, /didn't start/);
  });
});
