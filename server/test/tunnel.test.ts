import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type AddressInfo, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, before, describe, it } from "node:test";
import type { WebSocket } from "ws";
import { listeningPorts, parseLsof, parseSs, pipeTunnel } from "../src/tunnel.ts";

describe("which ports something listens on", () => {
  const savedPath = process.env.PATH;
  let bin: string;
  // Only the stand-ins are on PATH, so what the machine really runs doesn't matter.
  const tools = (ss: string, lsof: string) => {
    for (const [name, script] of [["ss", ss], ["lsof", lsof]]) {
      writeFileSync(join(bin, name), `#!/bin/sh\n${script}\n`);
      chmodSync(join(bin, name), 0o755);
    }
    process.env.PATH = bin;
  };

  before(() => {
    bin = mkdtempSync(join(tmpdir(), "kervan-fake-ports-"));
  });
  after(() => rmSync(bin, { recursive: true, force: true }));
  afterEach(() => {
    process.env.PATH = savedPath;
  });

  it("leaves out Kervan's own and the system's, sorts them, and keeps a port once with its process name", async () => {
    tools(
      `/bin/cat <<'OUT'
LISTEN 0 511 0.0.0.0:7420 0.0.0.0:* users:(("node",pid=1,fd=20))
LISTEN 0 511 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=2,fd=3))
LISTEN 0 511 0.0.0.0:5173 0.0.0.0:*
LISTEN 0 511 [::]:5173 [::]:* users:(("vite",pid=3,fd=4))
LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("next",pid=4,fd=5))
LISTEN 0 511 [::]:3000 [::]:*
OUT`,
      "exit 1",
    );
    assert.deepEqual(await listeningPorts([7420]), [
      { port: 3000, process: "next" },
      { port: 5173, process: "vite" },
    ]);
  });

  it("falls back to lsof where there's no ss", async () => {
    tools("exit 127", `/bin/cat <<'OUT'
COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
node 123 me 20u IPv4 0x1 0t0 TCP 127.0.0.1:8080 (LISTEN)
OUT`);
    assert.deepEqual(await listeningPorts([]), [{ port: 8080, process: "node" }]);
  });

  it("answers with nothing when neither tool works", async () => {
    tools("exit 1", "exit 1");
    assert.deepEqual(await listeningPorts([]), []);
  });

  it("skips lines it can't read", () => {
    assert.deepEqual(parseSs("\nnot enough\nLISTEN 0 1 nonsense 0.0.0.0:*\n"), []);
    assert.deepEqual(parseLsof("header\n\nnode 1 me 2u IPv4 0x1 0t0 TCP nonsense (LISTEN)\n"), []);
    assert.deepEqual(parseSs("LISTEN 0 1 *:3000 *:*"), [{ port: 3000 }]);
  });
});

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  sent: Buffer[] = [];
  private finish: (code?: number) => void = () => {};
  closed = new Promise<number | undefined>((resolve) => {
    this.finish = resolve;
  });
  close(code?: number) {
    this.finish(code);
  }
  send(chunk: Buffer) {
    this.sent.push(chunk);
  }
}

describe("a forwarded connection", () => {
  const servers: Server[] = [];
  afterEach(() => {
    for (const server of servers.splice(0)) server.close();
  });
  const listen = async (onData: (data: Buffer, reply: (text: string) => void) => void): Promise<number> => {
    const server = createServer((socket) => socket.on("data", (data) => onData(data, (text) => socket.write(text))));
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    return (server.address() as AddressInfo).port;
  };
  const tunnel = (ws: FakeSocket, port: number) => pipeTunnel(ws as unknown as WebSocket, port);
  const until = async (done: () => boolean) => {
    for (let i = 0; i < 400 && !done(); i++) await new Promise((resolve) => setTimeout(resolve, 5));
    assert.ok(done(), "timed out");
  };

  it("holds what arrives before the port answers, in order, whatever shape the frames take", async () => {
    let received = "";
    const port = await listen((data) => (received += data));
    const ws = new FakeSocket();
    tunnel(ws, port);
    ws.emit("message", Buffer.from("a"));
    ws.emit("message", [Buffer.from("b"), Buffer.from("c")]);
    ws.emit("message", new TextEncoder().encode("d").buffer);
    await until(() => received.length === 4);
    assert.equal(received, "abcd");
    ws.emit("message", Buffer.from("e"));
    await until(() => received === "abcde");
    ws.emit("close");
  });

  it("sends the port's bytes back, unless the socket has already gone", async () => {
    const port = await listen((data, reply) => reply(`echo ${data}`));
    const ws = new FakeSocket();
    tunnel(ws, port);
    ws.emit("message", Buffer.from("one"));
    await until(() => ws.sent.length === 1);
    assert.equal(ws.sent[0].toString(), "echo one");
    ws.readyState = 3;
    ws.emit("message", Buffer.from("two"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(ws.sent.length, 1);
    ws.emit("close");
  });

  it("closes the socket with a reason when nothing listens there", async () => {
    const server = createServer();
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const free = (server.address() as AddressInfo).port;
    await new Promise((resolve) => server.close(resolve));
    const ws = new FakeSocket();
    tunnel(ws, free);
    assert.equal(await ws.closed, 1011);
  });
});
