import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import WebSocket from "ws";
import { createKervanServer } from "../src/server.ts";

export const TEST_TOKEN = "test-token-0123456789";

export async function startServer(): Promise<{ server: Server; port: number; stop: () => Promise<void> }> {
  const server = createKervanServer({ token: TEST_TOKEN });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  const stop = () => new Promise<void>((resolve) => server.close(() => resolve()));
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
