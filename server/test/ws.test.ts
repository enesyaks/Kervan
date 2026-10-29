import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { VERSION } from "../src/server.ts";
import { isAuthorized } from "../src/ws.ts";
import { HELLO, TEST_TOKEN, nextMessage, openSocket, opened, rejectedStatus, send, startServer } from "./helpers.ts";

describe("websocket", () => {
  let port = 0;
  let stop: () => Promise<void>;
  const sockets: WebSocket[] = [];

  const connect = async () => {
    const ws = openSocket(port);
    sockets.push(ws);
    await opened(ws);
    return ws;
  };

  before(async () => {
    ({ port, stop } = await startServer());
  });

  after(async () => {
    for (const ws of sockets) ws.terminate();
    await stop();
  });

  it("rejects a missing token with 401", async () => {
    assert.equal(await rejectedStatus(openSocket(port, null)), 401);
  });

  it("rejects a wrong token with 401", async () => {
    assert.equal(await rejectedStatus(openSocket(port, "wrong-token-0123456789")), 401);
  });

  it("rejects an unknown path with 404", async () => {
    assert.equal(await rejectedStatus(openSocket(port, TEST_TOKEN, "/nope")), 404);
  });

  it("answers hello with welcome", async () => {
    const ws = await connect();
    send(ws, HELLO);
    assert.deepEqual(await nextMessage(ws), {
      type: "welcome",
      protocol: 1,
      server: { name: "kervan", version: VERSION },
      agents: ["fake"],
    });
  });

  it("requires hello before other messages", async () => {
    const ws = await connect();
    send(ws, { type: "ping", id: "p1" });
    const reply = await nextMessage(ws);
    assert.equal(reply.code, "hello_required");
    assert.equal(reply.id, "p1");
  });

  it("answers ping with pong after hello", async () => {
    const ws = await connect();
    send(ws, HELLO);
    await nextMessage(ws);
    send(ws, { type: "ping", id: "p2" });
    assert.deepEqual(await nextMessage(ws), { type: "pong", id: "p2" });
  });

  it("reports bad JSON and unknown types without closing", async () => {
    const ws = await connect();
    send(ws, "{not json");
    assert.equal((await nextMessage(ws)).code, "bad_message");
    send(ws, { type: "teleport" });
    assert.equal((await nextMessage(ws)).code, "unknown_type");
    send(ws, HELLO);
    assert.equal((await nextMessage(ws)).type, "welcome");
  });

  it("closes with 4000 on an unsupported protocol", async () => {
    const ws = await connect();
    const closed = new Promise<number>((resolve) => ws.once("close", (code: number) => resolve(code)));
    send(ws, { ...HELLO, protocol: 99 });
    assert.equal((await nextMessage(ws)).code, "unsupported_protocol");
    assert.equal(await closed, 4000);
  });
});

describe("isAuthorized", () => {
  it("accepts only the exact bearer token", () => {
    assert.equal(isAuthorized(`Bearer ${TEST_TOKEN}`, TEST_TOKEN), true);
    assert.equal(isAuthorized(TEST_TOKEN, TEST_TOKEN), false);
    assert.equal(isAuthorized(`Bearer ${TEST_TOKEN}x`, TEST_TOKEN), false);
    assert.equal(isAuthorized(undefined, TEST_TOKEN), false);
  });
});
