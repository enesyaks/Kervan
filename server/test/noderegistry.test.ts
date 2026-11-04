import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { NodeAgent } from "../src/node-agent.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import { fakeAgent, HELLO, Inbox, opened, openSocket, send, startServer } from "./helpers.ts";

const NODE_TOKEN = "node-token-0123456789";

describe("the agent catalog on a node", () => {
  let stop: () => Promise<void>;
  let port = 0;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent;
  let n = 0;
  let seenAdded: string[] = [];
  const ask = (message: object, ms = 20_000) => {
    const id = `c${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id, ms);
  };
  // As a node's machine would answer: its own models, and an address that only makes sense over there.
  const registry = {
    offer: async (added: Set<string>) => {
      seenAdded = [...added];
      return [{ id: "qwen-code", name: "Qwen", description: "", ollama: true, status: added.has("qwen-code") ? ("added" as const) : ("installable" as const) }];
    },
    ollama: async () => ({ running: true, url: "http://127.0.0.1:11434", models: ["model-on-the-node"] }),
    lmStudio: async () => ({ running: true, url: "http://127.0.0.1:1235", models: ["studio-model-on-the-node"] }),
    install: async (request: { agentId: string; ollamaModel?: string; lmStudioModel?: string }) => ({
      id: request.agentId,
      name: `Qwen (${request.ollamaModel ?? request.lmStudioModel})`,
      command: fakeAgent.command,
      args: fakeAgent.args,
      env: { OPENAI_BASE_URL: "http://127.0.0.1:11434/v1" },
    }),
  };

  before(async () => {
    ({ port, stop } = await startServer({ nodeToken: NODE_TOKEN }));
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: NODE_TOKEN, name: "kutu", workspacesDir: mkdtempSync(join(tmpdir(), "kervan-node-")), runner: new LocalAcpRunner(), registry });
    node.start();
    await inbox.waitFor((m) => m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "kutu" && x.connected));
  });

  after(async () => {
    node.stop();
    ws.terminate();
    await stop();
  });

  it("lists the node's agents and models, not the server's", async () => {
    const answer = await ask({ type: "agent.registry", node: "kutu" });
    assert.equal(answer.type, "agent.registry.result", JSON.stringify(answer));
    assert.deepEqual(answer.ollama.models, ["model-on-the-node"]);
    assert.deepEqual(answer.lmStudio.models, ["studio-model-on-the-node"]);
    assert.deepEqual(answer.agents.map((a: any) => [a.id, a.status]), [["qwen-code", "installable"]]);
  });

  it("adds an agent that runs on that node, under an id of its own", async () => {
    const answer = await ask({ type: "agent.install", agentId: "qwen-code", ollamaModel: "model-on-the-node", node: "kutu" }, 30_000);
    assert.equal(answer.type, "agent.list.result", JSON.stringify(answer));
    const added = answer.agents.find((a: any) => a.id === "qwen-code-kutu");
    assert.ok(added, JSON.stringify(answer.agents.map((a: any) => a.id)));
    assert.equal(added.node, "kutu");
    assert.equal(added.name, "Qwen (model-on-the-node)", "the model chosen reaches the node");
    assert.equal(answer.agents.filter((a: any) => a.id === "qwen-code").length, 0, "the server's own agents are untouched");
  });

  it("says its node is there", async () => {
    const list = await inbox.waitFor((m) => m.type === "agents.updated" && m.agentDetails.some((a: any) => a.id === "qwen-code-kutu"));
    assert.deepEqual(list.agentDetails.find((a: any) => a.id === "qwen-code-kutu"), { id: "qwen-code-kutu", name: "Qwen (model-on-the-node)", node: "kutu", online: true });
  });

  it("passes the LM Studio model chosen on to the node", async () => {
    const answer = await ask({ type: "agent.install", agentId: "qwen-code", lmStudioModel: "studio-model-on-the-node", node: "kutu" }, 30_000);
    assert.equal(answer.type, "agent.list.result", JSON.stringify(answer));
    assert.equal(answer.agents.find((a: any) => a.id === "qwen-code-kutu")?.name, "Qwen (studio-model-on-the-node)");
  });

  it("then shows it as added on that node, and only there", async () => {
    const onNode = await ask({ type: "agent.registry", node: "kutu" });
    assert.deepEqual(seenAdded, ["qwen-code"]);
    assert.equal(onNode.agents[0].status, "added");
    const list = await ask({ type: "agent.registry" });
    assert.notEqual(list.type, "error", JSON.stringify(list));
    assert.equal(list.agents.find((a: any) => a.id === "qwen-code")?.status === "added", false);
  });

  it("refuses a bad node name, and says when a node isn't there", async () => {
    assert.equal((await ask({ type: "agent.registry", node: "../x" })).code, "bad_message");
    assert.equal((await ask({ type: "agent.registry", node: "yok" })).code, "node_offline");
    assert.equal((await ask({ type: "agent.install", agentId: "qwen-code", node: "yok" })).code, "node_offline");
  });

  it("passes on what went wrong on the node", async () => {
    registry.offer = async () => {
      throw new Error("no registry here");
    };
    const answer = await ask({ type: "agent.registry", node: "kutu" });
    assert.equal(answer.code, "bad_message");
    assert.match(answer.message, /on node 'kutu': no registry here/);
  });

  it("says in the agent list when a node's agents can't be reached", async () => {
    const seen = inbox.received.length;
    node.stop();
    const update = await inbox.waitFor((m) => inbox.received.indexOf(m) >= seen && m.type === "agents.updated" && m.agentDetails.some((a: any) => a.node === "kutu" && a.online === false));
    assert.ok(update.agentDetails.every((a: any) => a.node === undefined ? a.online === undefined : true), "agents on the server itself have no such field");
  });
});

