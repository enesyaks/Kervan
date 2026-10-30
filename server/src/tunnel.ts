import { execFile } from "node:child_process";
import { connect } from "node:net";
import { promisify } from "node:util";
import type { RawData, WebSocket } from "ws";
import { log } from "./log.ts";
import type { ListeningPort } from "./protocol.ts";

const run = promisify(execFile);
export const TUNNEL_PATH = "/v1/tunnel";

/** The port in "0.0.0.0:3000", "[::]:3000", "*:3000" or "127.0.0.1.3000" (lsof uses ":", netstat "."). */
function portOf(address: string): number | undefined {
  const match = /[:.](\d+)$/.exec(address);
  return match ? Number(match[1]) : undefined;
}

/** Parses `ss -ltnpH`: "LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=1,fd=20))". */
export function parseSs(output: string): ListeningPort[] {
  return output.split("\n").flatMap((line): ListeningPort[] => {
    const columns = line.trim().split(/\s+/);
    if (columns.length < 4) return [];
    const port = portOf(columns[3]);
    const process = /users:\(\("([^"]+)"/.exec(line)?.[1];
    return port ? [{ port, ...(process ? { process } : {}) }] : [];
  });
}

/** Parses `lsof -nP -iTCP -sTCP:LISTEN`: "node 123 me 20u IPv4 0x… 0t0 TCP *:3000 (LISTEN)". */
export function parseLsof(output: string): ListeningPort[] {
  return output.split("\n").slice(1).flatMap((line): ListeningPort[] => {
    const columns = line.trim().split(/\s+/);
    const address = columns.at(-2);
    const port = address ? portOf(address) : undefined;
    return port ? [{ port, process: columns[0] }] : [];
  });
}

/** Ports something listens on, one entry per port, without Kervan's own and the system's (below 1024). */
export async function listeningPorts(own: number[]): Promise<ListeningPort[]> {
  let ports: ListeningPort[] = [];
  try {
    ports = parseSs((await run("ss", ["-ltnpH"])).stdout);
  } catch {
    try {
      ports = parseLsof((await run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])).stdout);
    } catch {
      return [];
    }
  }
  const seen = new Map<number, ListeningPort>();
  for (const entry of ports) {
    if (entry.port < 1024 || own.includes(entry.port)) continue;
    if (!seen.has(entry.port) || (!seen.get(entry.port)!.process && entry.process)) seen.set(entry.port, entry);
  }
  return [...seen.values()].sort((a, b) => a.port - b.port);
}

/**
 * One forwarded connection: bytes from the Mac's WebSocket go to the port on this machine and back.
 * Dev servers usually listen only on localhost, which is why the app can't reach them directly.
 */
export function pipeTunnel(ws: WebSocket, port: number): void {
  const socket = connect({ host: "127.0.0.1", port });
  const pending: Buffer[] = [];
  let open = false;
  socket.on("connect", () => {
    open = true;
    for (const chunk of pending.splice(0)) socket.write(chunk);
  });
  socket.on("data", (chunk) => {
    if (ws.readyState === ws.OPEN) ws.send(chunk, { binary: true });
  });
  socket.on("error", (error) => {
    log("debug", "tunnel socket error", { port, error: error.message });
    ws.close(1011, "port unreachable");
  });
  socket.on("close", () => ws.close(1000));
  ws.on("message", (data: RawData) => {
    const chunk = Buffer.isBuffer(data) ? data : Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data);
    if (open) socket.write(chunk);
    else pending.push(chunk);
  });
  ws.on("close", () => socket.destroy());
}
