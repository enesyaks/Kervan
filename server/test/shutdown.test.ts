import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync } from "node:fs";
import { Agent, get } from "node:http";
import { connect, createServer, type AddressInfo, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, it } from "node:test";
import { TEST_TOKEN, openSocket, opened, startServer } from "./helpers.ts";

// Well under main.ts's 5-second fallback, which exits with code 1.
const PROMPT_MS = 3000;

async function freePort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const { port } = probe.address() as AddressInfo;
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

/** The real server process, so the exit code and the signal handling are covered too. */
async function startProcess(): Promise<{ child: ChildProcess; port: number }> {
  const port = await freePort();
  const child = spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], {
    env: {
      ...process.env,
      KERVAN_TOKEN: TEST_TOKEN,
      KERVAN_PORT: String(port),
      KERVAN_DATA_DIR: mkdtempSync(join(tmpdir(), "kervan-shutdown-")),
    },
    stdio: "ignore",
  });
  const deadline = Date.now() + 10_000;
  for (;;) {
    const up = await fetch(`http://127.0.0.1:${port}/health`).then((res) => res.ok, () => false);
    if (up) return { child, port };
    if (Date.now() > deadline) throw new Error("server did not start");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

async function terminate(child: ChildProcess): Promise<{ code: number | null; elapsed: number }> {
  const exited = once(child, "exit");
  const started = Date.now();
  child.kill("SIGTERM");
  const [code] = await exited;
  return { code, elapsed: Date.now() - started };
}

function rawConnect(port: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = connect(port, "127.0.0.1", () => resolve(socket));
    socket.once("error", reject);
  });
}

describe("shutdown", () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => {
    for (const cleanup of cleanups.splice(0)) cleanup();
  });

  it("exits 0 at once with a WebSocket client and an idle keep-alive connection", async () => {
    const { child, port } = await startProcess();
    cleanups.push(() => child.kill("SIGKILL"));
    const ws = openSocket(port);
    await opened(ws);
    const closed = once(ws, "close");
    const agent = new Agent({ keepAlive: true });
    cleanups.push(() => agent.destroy());
    await new Promise<void>((resolve, reject) => {
      get({ host: "127.0.0.1", port, path: "/health", agent }, (res) => res.resume().once("end", resolve)).once("error", reject);
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(Object.keys(agent.freeSockets).length, 1, "the keep-alive connection stays open");

    const { code, elapsed } = await terminate(child);

    assert.equal(code, 0);
    assert.ok(elapsed < PROMPT_MS, `took ${elapsed}ms`);
    assert.equal((await closed)[0], 1001);
  });

  it("exits 0 at once when a WebSocket client never answers the close frame", async () => {
    const { child, port } = await startProcess();
    cleanups.push(() => child.kill("SIGKILL"));
    const socket = await rawConnect(port);
    cleanups.push(() => socket.destroy());
    socket.write(
      `GET /v1/ws HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${TEST_TOKEN}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n` +
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    );
    const [reply] = await once(socket, "data");
    assert.match(String(reply), /^HTTP\/1\.1 101/);
    socket.on("error", () => {}); // the server cuts this one off

    const { code, elapsed } = await terminate(child);

    assert.equal(code, 0);
    assert.ok(elapsed < PROMPT_MS, `took ${elapsed}ms`);
  });

  it("answers a running request, then drops its keep-alive connection", async () => {
    const { server, port, stop } = await startServer();
    cleanups.push(() => void stop());
    const socket = await rawConnect(port);
    cleanups.push(() => socket.destroy());
    socket.write("GET /health HTTP/1.1\r\n");
    await new Promise((resolve) => setTimeout(resolve, 50));

    const started = Date.now();
    const done = server.shutdown();
    const answered = once(socket, "data");
    socket.write("Host: localhost\r\n\r\n");
    assert.match(String((await answered)[0]), /^HTTP\/1\.1 200/);
    await done;

    const elapsed = Date.now() - started;
    assert.ok(elapsed < PROMPT_MS, `took ${elapsed}ms`);
  });
});
