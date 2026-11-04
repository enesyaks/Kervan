import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, describe, it } from "node:test";
import { WebSocketServer } from "ws";
import { NodeAgent, type NodeAgentOptions } from "../src/node-agent.ts";
import { LocalAcpRunner } from "../src/runner.ts";

// A hub whose side of the connection has gone, as after a Mac's sleep, looks like this to the node: the socket
// stays open and nothing ever arrives, so nothing ever closes it.
describe("a node noticing that the hub has gone", () => {
  const folder = mkdtempSync(join(tmpdir(), "kervan-heartbeat-"));
  let hub: WebSocketServer;
  let node: NodeAgent | undefined;
  const listen = async (autoPong: boolean) => {
    hub = new WebSocketServer({ port: 0, host: "127.0.0.1", autoPong });
    await new Promise((resolve) => hub.once("listening", resolve));
    return `ws://127.0.0.1:${(hub.address() as AddressInfo).port}`;
  };
  const connections = () => {
    let count = 0;
    hub.on("connection", () => count++);
    return () => count;
  };
  const startNode = (hubUrl: string, options: Partial<NodeAgentOptions> = {}) => {
    node = new NodeAgent({
      hubUrls: [hubUrl],
      token: "t",
      name: "n",
      workspacesDir: folder,
      runner: new LocalAcpRunner(),
      registry: { offer: async () => [], ollama: async () => ({ running: false, url: "", models: [] }), lmStudio: async () => ({ running: false, url: "", models: [] }), install: async () => { throw new Error("unused"); } } as unknown as NodeAgentOptions["registry"],
      ...options,
    });
    node.start();
  };
  const until = async (check: () => boolean, what: string) => {
    for (let i = 0; i < 400 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.ok(check(), what);
  };

  afterEach(async () => {
    node?.stop();
    node = undefined;
    for (const client of hub.clients) client.terminate();
    await new Promise((resolve) => hub.close(resolve));
  });
  after(() => rmSync(folder, { recursive: true, force: true }));

  it("connects again when the hub stops answering", async () => {
    const url = await listen(false);
    const count = connections();
    startNode(url, { heartbeatMs: 40 });
    await until(() => count() >= 2, "the node should have reconnected");
  });

  it("keeps the connection while the hub answers", async () => {
    const url = await listen(true);
    const count = connections();
    startNode(url, { heartbeatMs: 40 });
    await until(() => count() === 1, "connected");
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(count(), 1, "seven rounds went by, with answers");
  });

  it("takes anything from the hub as a sign of life", async () => {
    const url = await listen(false);
    const count = connections();
    const chatter = setInterval(() => {
      for (const client of hub.clients) client.send(JSON.stringify({ note: "still here" }));
    }, 10);
    try {
      startNode(url, { heartbeatMs: 40 });
      await until(() => count() === 1, "connected");
      await new Promise((resolve) => setTimeout(resolve, 300));
      assert.equal(count(), 1);
    } finally {
      clearInterval(chatter);
    }
  });

  it("connects again right after a jump in time, the mark of having slept, even though the hub answers", async () => {
    const url = await listen(true);
    const count = connections();
    let time = 1_000_000;
    startNode(url, { heartbeatMs: 40, now: () => time });
    await until(() => count() === 1, "connected");
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(count(), 1, "time standing still isn't sleep");
    time += 60 * 60_000;
    await until(() => count() >= 2, "the node should have reconnected after waking");
  });

  it("stops checking once stopped", async () => {
    const url = await listen(false);
    const count = connections();
    startNode(url, { heartbeatMs: 40 });
    await until(() => count() === 1, "connected");
    node!.stop();
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(count(), 1);
  });
});
