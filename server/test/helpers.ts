import type { Server } from "node:http";
import { mkdtempSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { LocalAcpRunner } from "../src/runner.ts";
import { createKervanServer } from "../src/server.ts";
import { SessionManager } from "../src/sessions.ts";

export const TEST_TOKEN = "test-token-0123456789";

const fakeAgent = { command: process.execPath, args: [join(import.meta.dirname, "fixtures/fake-agent.ts")] };

export async function startServer(): Promise<{ server: Server; port: number; stop: () => Promise<void> }> {
  const workspaces = mkdtempSync(join(tmpdir(), "kervan-test-"));
  const sessions = new SessionManager(new LocalAcpRunner(), new Map([["fake", fakeAgent]]), workspaces);
  const server = createKervanServer({ token: TEST_TOKEN, sessions });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  const stop = () =>
    new Promise<void>((resolve) => {
      sessions.closeAll();
      server.close(() => resolve());
    });
  return { server, port, stop };
}

export function openSocket(port: number, token: string | null = TEST_TOKEN, path = "/v1/ws"): WebSocket {
  const headers: Record<string, string> = token ? { authorization: `Bearer ${token}` } : {};
  return new WebSocket(`ws://127.0.0.1:${port}${path}`, { headers });
}

export function opened(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
}

// Resolves with the HTTP status of a rejected upgrade.
export function rejectedStatus(ws: WebSocket): Promise<number> {
  return new Promise((resolve, reject) => {
    ws.once("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0));
    ws.once("open", () => reject(new Error("socket opened, expected rejection")));
  });
}

export function nextMessage(ws: WebSocket): Promise<any> {
  return new Promise((resolve) => ws.once("message", (data) => resolve(JSON.parse(data.toString()))));
}

export function send(ws: WebSocket, message: unknown): void {
  ws.send(typeof message === "string" ? message : JSON.stringify(message));
}

export const HELLO = { type: "hello", protocol: 1, client: { name: "test", version: "0.0.0" } };

/** Buffers every message so tests can wait for one that matches, in any order. */
export class Inbox {
  readonly received: any[] = [];
  private waiters: { match: (m: any) => boolean; resolve: (m: any) => void }[] = [];

  constructor(ws: WebSocket) {
    ws.on("message", (data) => {
      const message = JSON.parse(data.toString());
      this.received.push(message);
      this.waiters = this.waiters.filter((w) => (w.match(message) ? (w.resolve(message), false) : true));
    });
  }

  waitFor(match: (m: any) => boolean, timeoutMs = 5000): Promise<any> {
    const existing = this.received.find(match);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for message")), timeoutMs);
      this.waiters.push({ match, resolve: (m) => (clearTimeout(timer), resolve(m)) });
    });
  }
}
