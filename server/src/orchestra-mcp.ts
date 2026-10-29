// The stdio MCP server a lead agent runs to reach Kervan's orchestration tools.
// It speaks MCP (newline-delimited JSON-RPC) on stdin/stdout and forwards tools/list and
// tools/call to the Kervan server over its Unix socket. It holds no state of its own.
import { request } from "node:http";
import { createInterface } from "node:readline";
import { VERSION } from "./version.ts";

const socketPath = process.env.KERVAN_ORCHESTRA_SOCKET ?? "";
const token = process.env.KERVAN_ORCHESTRA_TOKEN ?? "";
const PROTOCOL_VERSION = "2025-06-18";

interface RpcMessage {
  jsonrpc: "2.0";
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

function hub(method: "GET" | "POST", path: string, body?: unknown): Promise<any> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const req = request(
      {
        socketPath,
        path,
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...(payload ? { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          if (res.statusCode !== 200) return reject(new Error(`Kervan answered ${res.statusCode}: ${text}`));
          resolve(JSON.parse(text));
        });
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

function write(message: object): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
}

async function handle(message: RpcMessage): Promise<void> {
  const { id, method, params } = message;
  if (id === undefined || id === null) return; // notifications (initialized, cancelled) need no answer
  try {
    switch (method) {
      case "initialize": {
        const requested = typeof params?.protocolVersion === "string" ? params.protocolVersion : PROTOCOL_VERSION;
        return write({
          id,
          result: {
            protocolVersion: requested,
            capabilities: { tools: {} },
            serverInfo: { name: "kervan", version: VERSION },
            instructions: "Start helper agents for subtasks, message them and collect their replies.",
          },
        });
      }
      case "ping":
        return write({ id, result: {} });
      case "tools/list":
        return write({ id, result: await hub("GET", "/tools") });
      case "tools/call":
        return write({ id, result: await hub("POST", "/call", { name: params?.name, arguments: params?.arguments ?? {} }) });
      default:
        return write({ id, error: { code: -32601, message: `method not found: ${method}` } });
    }
  } catch (error) {
    write({ id, result: { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], isError: true } });
  }
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  if (line.trim() === "") return;
  let message: RpcMessage;
  try {
    message = JSON.parse(line);
  } catch {
    return write({ id: null, error: { code: -32700, message: "parse error" } });
  }
  void handle(message);
});
lines.on("close", () => process.exit(0));
