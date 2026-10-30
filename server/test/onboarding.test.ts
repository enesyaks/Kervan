import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { NodeAgent } from "../src/node-agent.ts";
import { installScript } from "../src/onboarding.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, rejectedStatus, send, startServer } from "./helpers.ts";

describe("adding a node from the app", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let node: NodeAgent | undefined;
  let n = 0;

  const invite = async (name: string) => {
    const id = `i${++n}`;
    send(ws, { type: "node.invite", id, name });
    return inbox.waitFor((m) => (m.type === "node.invited" || m.type === "error") && m.id === id);
  };
  const url = (path: string) => `http://127.0.0.1:${port}${path}`;
  const joinHub = (code: string) =>
    fetch(url("/v1/node/join"), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code }) });

  before(async () => {
    ({ port, sessions, stop } = await startServer());
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

  it("serves an install script and the code for a valid invite only", async () => {
    const { code, name, expiresAt } = await invite("gpu");
    assert.equal(name, "gpu");
    assert.ok(Date.parse(expiresAt) > Date.now());

    const script = await (await fetch(url(`/v1/node/install?code=${code}`))).text();
    assert.match(script, new RegExp(`HUB_WS='ws://127.0.0.1:${port},.*\\.local:${port}'`), "every hub address, the one used first");
    assert.match(script, /NAME='gpu'/);
    assert.equal((await fetch(url("/v1/node/install?code=nope"))).status, 403);

    const bundle = Buffer.from(await (await fetch(url(`/v1/node/bundle.tar.gz?code=${code}`))).arrayBuffer());
    const dir = mkdtempSync(join(tmpdir(), "kervan-bundle-"));
    writeFileSync(join(dir, "b.tgz"), bundle);
    const files = execFileSync("tar", ["-tzf", join(dir, "b.tgz")], { encoding: "utf8" });
    assert.match(files, /src\/node-main\.ts/);
    assert.match(files, /package-lock\.json/);
    assert.doesNotMatch(files, /node_modules\/|\.\/test\//, "no dependencies or tests in the bundle");

    assert.match((await invite("Kötü Ad")).message, /lowercase/);
  });

  it("writes a script bash accepts", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-script-"));
    writeFileSync(join(dir, "install.sh"), installScript({ hubHttp: "http://kervan:7420", hubWs: "ws://kervan:7420", code: "a'b", name: "gpu" }));
    execFileSync("bash", ["-n", join(dir, "install.sh")]);
  });

  it("trades an invite once for the node's own token, which only that node can use", async () => {
    const { code } = await invite("gpu");
    const joined = (await (await joinHub(code)).json()) as { name: string; token: string };
    assert.equal(joined.name, "gpu");
    assert.equal((await joinHub(code)).status, 403, "an invite works once");

    assert.equal(await rejectedStatus(openSocket(port, joined.token, "/v1/node")), 401, "without the node's name the token is useless");

    const nodeDir = mkdtempSync(join(tmpdir(), "kervan-joined-"));
    node = new NodeAgent({ hubUrls: [`ws://127.0.0.1:${port}`], token: joined.token, name: "gpu", workspacesDir: nodeDir, runner: new LocalAcpRunner() });
    node.start();
    await inbox.waitFor((m) => m.type === "nodes.updated" && m.nodes.some((x: any) => x.name === "gpu" && x.connected));
    assert.ok(sessions.nodes?.isConnected("gpu"));
  });

  it("removes a node: it is disconnected and its token stops working", async () => {
    send(ws, { type: "node.remove", id: "r1", name: "gpu" });
    const { nodes } = await inbox.waitFor((m) => m.type === "node.list.result" && m.id === "r1");
    assert.deepEqual(nodes, []);
    node?.stop();
    assert.equal(sessions.nodes?.isConnected("gpu"), false);
    assert.equal(sessions.nodes?.authorize("gpu", "anything"), false);
  });
});
