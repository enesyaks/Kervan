import assert from "node:assert/strict";
import { spawn } from "node:child_process";
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
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
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
    assert.deepEqual(sessions.agentDetails.find((a) => a.id === "uzak"), { id: "uzak", name: "Uzak", node: "kutu", online: true });

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
    send(ws, { type: "session.create", id: "c3", agent: "uzak", split: true });
    assert.match((await inbox.waitFor((m) => m.type === "error" && m.id === "c3")).message, /a lead must run on this server/);
  });

  it("refuses project work for a node's agent when it's set up, not when it comes due", async () => {
    const project = await sessions.projects!.save({ name: "Sunucuda" });
    assert.throws(() => sessions.board!.save({ projectId: project.id, title: "Kart", prompt: "yap", agent: "uzak" }), /projects live on this server/);
    const task = { title: "Görev", agent: "uzak", prompt: "yap", when: { kind: "interval", minutes: 60 }, timeZone: "UTC" };
    assert.throws(() => sessions.scheduler!.save({ ...task, projectId: project.id }), /projects live on this server/);
    const saved = sessions.scheduler!.save(task);
    assert.equal(saved.agent, "uzak");
    sessions.scheduler!.remove(saved.id);
  });

  it("tells a lead where each agent runs", () => {
    assert.deepEqual(sessions.helperChoices().agents.find((a) => a.id === "uzak"), { id: "uzak", name: "Uzak", node: "kutu", online: true });
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

    const count = sessions.list().length;
    send(ws, { type: "session.create", id: "off2", agent: "uzak" });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === "off2")).code, "node_offline");
    assert.equal(sessions.list().length, count, "no session is left behind that could never start");

    mark = inbox.received.length;
    startNode();
    await connected(true);
    assert.equal(await ask("whoami"), before, "the same agent conversation, resumed on the node");
  });
});

describe("answering only over Tailscale", () => {
  it("takes the tailnet and this machine, and nothing else", async () => {
    const { allowedConnection, isTailnetAddress } = await import("../src/tailnet.ts");
    for (const address of ["100.64.0.1", "100.92.238.61", "100.127.255.255", "::ffff:100.92.238.61", "fd7a:115c:a1e0::1"]) assert.ok(isTailnetAddress(address), address);
    for (const address of ["100.63.255.255", "100.128.0.1", "192.168.1.21", "10.0.0.1", "fd00::1", "100.64.0"]) assert.ok(!isTailnetAddress(address), address);
    assert.ok(allowedConnection("100.84.142.87", "100.92.238.61"));
    assert.ok(allowedConnection("::ffff:127.0.0.1", "::ffff:127.0.0.1"));
    assert.ok(allowedConnection("::1", "::1"));
    assert.ok(!allowedConnection("192.168.1.5", "192.168.1.32"), "from the home network");
    assert.ok(!allowedConnection("192.168.1.5", "100.92.238.61"), "a home address asking for the Tailscale one");
    assert.ok(!allowedConnection("100.84.142.87", "192.168.1.32"), "a Tailscale address arriving on the home side");
    assert.ok(!allowedConnection("127.0.0.1", "192.168.1.32"), "a spoofed loopback");
    assert.ok(!allowedConnection(undefined, "100.92.238.61"));
  });

  it("offers only Tailscale addresses when that's all it answers on", async () => {
    const { NodeHub } = await import("../src/nodes.ts");
    process.env.KERVAN_TAILNET_ONLY = "1";
    try {
      const hub = new NodeHub(join(mkdtempSync(join(tmpdir(), "kervan-nodes-")), "nodes.json"));
      assert.ok(hub.addresses().every((address) => address.kind === "tailscale"));
    } finally {
      delete process.env.KERVAN_TAILNET_ONLY;
    }
  });
});

describe("hub addresses offered to new nodes", () => {
  it("notices when an address appears, as when Tailscale signs in after Kervan started", async () => {
    const { NodeHub } = await import("../src/nodes.ts");
    const entry = (address: string, cidr: string) => ({ address, cidr, internal: false, family: "IPv4", netmask: "", mac: "", scopeid: 0 }) as never;
    const hub = new NodeHub(join(mkdtempSync(join(tmpdir(), "kervan-nodes-")), "nodes.json"));
    const lan = { enp6s18: [entry("192.168.1.32", "192.168.1.32/24")] };
    assert.equal(hub.addressesChanged(lan), true, "the first look counts as a change");
    assert.equal(hub.addressesChanged(lan), false);
    assert.equal(hub.addressesChanged({ ...lan, tailscale0: [entry("100.92.238.61", "100.92.238.61/32")] }), true);
  });

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

  it("puts the MagicDNS name on Tailscale addresses only", async () => {
    const { hubAddresses } = await import("../src/nodes.ts");
    const entry = (address: string, cidr: string) =>
      ({ address, cidr, internal: false, family: "IPv4", netmask: "", mac: "", scopeid: 0 }) as never;
    const found = hubAddresses(
      7420,
      { tailscale0: [entry("100.66.121.56", "100.66.121.56/32")], en0: [entry("192.168.1.21", "192.168.1.21/24")] },
      "kervan.tail1234.ts.net",
    );
    assert.deepEqual(found, [
      { address: "100.66.121.56:7420", kind: "tailscale", host: "kervan.tail1234.ts.net" },
      { address: "192.168.1.21:7420", kind: "lan", network: "192.168.1.0/24" },
    ]);
  });
});

describe("finding a hub whose address changed", () => {
  it("tries the next address, then remembers every address the hub gave it", async () => {
    const { mkdtempSync, readFileSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const { NodeAgent } = await import("../src/node-agent.ts");
    const { LocalAcpRunner } = await import("../src/runner.ts");
    const { startServer } = await import("./helpers.ts");

    const { port, sessions, stop } = await startServer({ nodeToken: "node-token-0123456789" });
    const dir = mkdtempSync(join(tmpdir(), "kervan-hubs-"));
    const stateFile = join(dir, "hub.json");
    const good = `ws://127.0.0.1:${port}`;
    const make = (hubUrls: string[]) =>
      new NodeAgent({ hubUrls, stateFile, token: "node-token-0123456789", name: "gezgin", workspacesDir: join(dir, "ws"), runner: new LocalAcpRunner() });
    const until = async (check: () => boolean) => {
      for (let i = 0; i < 200 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 25));
      assert.ok(check(), "timed out");
    };
    try {
      // The first address answers nothing (the hub moved); the second works.
      const first = make(["ws://127.0.0.1:1", good]);
      first.start();
      await until(() => sessions.nodes!.isConnected("gezgin"));
      await until(() => first.knownHubs[0] === good);
      const saved = JSON.parse(readFileSync(stateFile, "utf8")).hubs as string[];
      assert.equal(saved[0], good, "the address that worked comes first");
      assert.ok(saved.some((url) => url.endsWith(".local:" + port)), "the hub's mDNS name is learned too");
      assert.equal(sessions.nodes!.list().find((n) => n.name === "gezgin")?.via, `127.0.0.1:${port}`);
      first.stop();
      await until(() => !sessions.nodes!.isConnected("gezgin"));

      // Restarted with only a dead address configured, it still finds the hub from what it learned.
      const second = make(["ws://127.0.0.1:1"]);
      second.start();
      await until(() => sessions.nodes!.isConnected("gezgin"));
      second.stop();
    } finally {
      await stop();
    }
  });
});

describe("a node started by hand", () => {
  it("keeps running while its hub can't be reached", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-node-"));
    const child = spawn(process.execPath, [join(import.meta.dirname, "../src/node-main.ts")], {
      env: { PATH: process.env.PATH, HOME: dir, KERVAN_HUB_URL: "ws://127.0.0.1:9", KERVAN_NODE_TOKEN: NODE_TOKEN, KERVAN_NODE_NAME: "bekle", KERVAN_WORKSPACES_DIR: join(dir, "w") },
      stdio: "ignore",
    });
    const exited = new Promise((resolve) => child.once("exit", () => resolve("exited")));
    const outcome = await Promise.race([exited, new Promise((resolve) => setTimeout(() => resolve("running"), 2_000))]);
    child.kill("SIGKILL");
    assert.equal(outcome, "running");
  });

  it("makes its workspaces folder when it doesn't exist yet", async () => {
    const { port, stop } = await startServer({ nodeToken: NODE_TOKEN });
    const ws = openSocket(port);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const workspacesDir = join(mkdtempSync(join(tmpdir(), "kervan-node-")), "not", "yet");
    const node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "elle", workspacesDir, runner: new LocalAcpRunner() });
    node.start();
    await inbox.waitFor((m) => m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "elle" && x.connected));
    send(ws, { type: "agent.save", id: "s1", agent: { id: "elde", name: "Elde", command: fakeAgent.command, args: fakeAgent.args, node: "elle" } });
    const answer = await inbox.waitFor((m) => m.id === "s1", 20_000);
    assert.equal(answer.type, "agent.list.result", JSON.stringify(answer));
    assert.ok(existsSync(workspacesDir));
    node.stop();
    ws.terminate();
    await stop();
  });
});

