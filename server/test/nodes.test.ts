import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { NodeAgent } from "../src/node-agent.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, TEST_TOKEN, fakeAgent, openSocket, opened, rejectedStatus, send, startServer } from "./helpers.ts";

const NODE_TOKEN = "node-token-0123456789";

describe("agents on another node", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent;
  const nodeDir = mkdtempSync(join(tmpdir(), "kervan-node-"));
  let n = 0;
  let sessionId = "";

  const startNode = () => {
    node = new NodeAgent({ hubUrl: `ws://127.0.0.1:${port}`, token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
    node.start();
  };
  const connected = (value: boolean) =>
    inbox.waitFor((m) => m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "kutu" && x.connected === value) && inbox.received.indexOf(m) >= mark);
  let mark = 0;

  const ask = async (text: string, extra: object = {}) => {
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id: `p${++n}`, sessionId, text, ...extra });
    const reply = await inbox.waitFor(
      (m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk",
      10_000,
    );
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end", 10_000);
    return reply.event.text as string;
  };

  const http = (method: string, path: string, body?: string) =>
    fetch(`http://127.0.0.1:${port}/v1/sessions/${sessionId}/files${path}`, {
      method,
      headers: { authorization: `Bearer ${TEST_TOKEN}` },
      ...(body !== undefined ? { body } : {}),
    });

  before(async () => {
    ({ port, sessions, stop } = await startServer({ nodeToken: NODE_TOKEN }));
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
  });

  after(async () => {
    node?.stop();
    ws.terminate();
    await stop();
  });

  it("refuses nodes without the node token, or with the app's token", async () => {
    assert.equal(await rejectedStatus(openSocket(port, "wrong-token-0123456789", "/v1/node")), 401);
    assert.equal(await rejectedStatus(openSocket(port, TEST_TOKEN, "/v1/node")), 401);
  });

  it("lists a node once it connects, and runs an agent assigned to it", async () => {
    mark = inbox.received.length;
    startNode();
    await connected(true);
    send(ws, { type: "node.list", id: "n1" });
    const { nodes } = await inbox.waitFor((m) => m.type === "node.list.result" && m.id === "n1");
    assert.deepEqual(nodes.map((x: any) => [x.name, x.connected]), [["kutu", true]]);

    // Saving tries the agent first, on the node.
    send(ws, { type: "agent.save", id: "a1", agent: { id: "uzak", name: "Uzak", command: fakeAgent.command, args: fakeAgent.args, node: "kutu" } });
    const saved = await inbox.waitFor((m) => m.type === "agent.list.result" && m.id === "a1", 15_000);
    assert.deepEqual(saved.nodes, ["local", "kutu"]);
    assert.deepEqual(sessions.agentDetails.find((a) => a.id === "uzak"), { id: "uzak", name: "Uzak", node: "kutu" });

    send(ws, { type: "session.create", id: "c1", agent: "uzak" });
    ({ session: { id: sessionId } } = await inbox.waitFor((m) => m.type === "session.created" && m.id === "c1"));
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle");
    assert.match(await ask("whoami"), /^fake-\d+$/);
    assert.ok(existsSync(join(nodeDir, sessionId)), "the workspace is on the node");
  });

  it("brings the node agent's approvals and settings to the app", async () => {
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id: "t1", sessionId, text: "tool" });
    const request = await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.event.kind === "permission_request");
    send(ws, { type: "session.permission", id: "t2", sessionId, requestId: request.event.requestId, optionId: "yes" });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "tool_call_update" && m.event.status === "completed");
    await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "session.event" && m.event.kind === "turn_end");

    send(ws, { type: "session.config", id: "s1", sessionId, configId: "model", value: "smart" });
    await inbox.waitFor((m) => m.type === "ok" && m.id === "s1");
    assert.equal(await ask("modelcheck"), "model: smart");
  });

  it("uploads, lists and downloads files in the node's workspace, and attaches them", async () => {
    assert.equal((await http("PUT", "/notlar/a.txt", "merhaba node")).status, 201);
    assert.equal(readFileSync(join(nodeDir, sessionId, "notlar/a.txt"), "utf8"), "merhaba node");
    const listing = (await (await http("GET", "")).json()) as { entries: { path: string }[] };
    assert.ok(listing.entries.some((e) => e.path === "notlar/a.txt"));
    assert.equal(await (await http("GET", "/notlar/a.txt")).text(), "merhaba node");
    assert.equal((await http("GET", "/yok.txt")).status, 404);
    assert.equal((await http("GET", "/..%2F..%2Fetc%2Fpasswd")).status, 400);

    const reply = await ask("ekteki dosya", { attachments: ["notlar/a.txt"] });
    assert.equal(reply, `files: file://${join(nodeDir, sessionId, "notlar/a.txt")}`);
  });

  it("keeps leads and skills on this server", async () => {
    send(ws, { type: "session.create", id: "c2", agent: "uzak", orchestrate: true });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "c2")).message, /a lead must run on this server/);
  });

  it("waits out a node that goes away, and resumes the conversation when it is back", async () => {
    const before = await ask("whoami");
    mark = inbox.received.length;
    node.stop();
    await connected(false);
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "notice" && inbox.received.indexOf(m) >= mark);

    send(ws, { type: "session.prompt", id: "off", sessionId, text: "whoami" });
    const refused = await inbox.waitFor((m) => m.type === "error" && m.id === "off");
    assert.equal(refused.code, "node_offline");
    assert.equal((await http("GET", "")).status, 503);
    assert.equal(sessions.list().find((s) => s.id === sessionId)?.status, "idle", "the session isn't broken by it");

    mark = inbox.received.length;
    startNode();
    await connected(true);
    assert.equal(await ask("whoami"), before, "the same agent conversation, resumed on the node");
  });
});

describe("hub addresses offered to new nodes", () => {
  it("lists Tailscale first, then private LAN addresses with their network, and skips the rest", async () => {
    const { hubAddresses } = await import("../src/nodes.ts");
    const entry = (address: string, cidr: string, internal = false) =>
      ({ address, cidr, internal, family: "IPv4", netmask: "", mac: "", scopeid: 0 }) as never;
    const found = hubAddresses(7420, {
      lo: [entry("127.0.0.1", "127.0.0.1/8", true)],
      enp6s18: [entry("192.168.1.21", "192.168.1.21/24")],
      tailscale0: [entry("100.66.121.56", "100.66.121.56/32")],
      docker0: [entry("172.17.0.1", "172.17.0.1/16")],
      wan0: [entry("85.10.1.2", "85.10.1.2/24")],
    });
    assert.deepEqual(found, [
      { address: "100.66.121.56:7420", kind: "tailscale" },
      { address: "192.168.1.21:7420", kind: "lan", network: "192.168.1.0/24" },
    ]);
  });
});
