import { createHash, randomBytes } from "node:crypto";
import { rmSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";
import type { HelperSummary, SessionManager } from "./sessions.ts";

/** The MCP server name lead agents see; their tools show up as e.g. `kervan.start_helper`. */
export const ORCHESTRA_MCP_NAME = "kervan";

const BRIDGE = join(import.meta.dirname, "orchestra-mcp.ts");
const MAX_BODY = 256 * 1024;
const DEFAULT_WAIT_SEC = 50; // under Codex's 60 s default tool timeout; the lead calls again if not done
const MAX_WAIT_SEC = 600;

interface Tool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const text = (description: string) => ({ type: "string", description });

export const TOOLS: Tool[] = [
  {
    name: "list_agents",
    description: "Agents and roles you can start helpers with.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "start_helper",
    description:
      "Start a helper agent on a self-contained task. It works in your folder and answers you, not the user. " +
      "Returns at once with the helper's id; call wait_for_helper to get its reply.",
    inputSchema: {
      type: "object",
      properties: {
        name: text("Short name shown to the user, e.g. 'Test writer'."),
        task: text("Everything the helper needs to know; it can't see your conversation."),
        agent: text("Agent id from list_agents. Give this or role."),
        role: text("Role id from list_agents; uses the role's agent and instructions."),
        isolate: {
          type: "boolean",
          description: "In a git repository (default true): work on its own branch in a separate worktree, merged later with merge_helper.",
        },
      },
      required: ["name", "task"],
    },
  },
  {
    name: "message_helper",
    description: "Send a follow-up to a helper that has finished its turn.",
    inputSchema: {
      type: "object",
      properties: { helperId: text("Id from start_helper."), text: text("The message.") },
      required: ["helperId", "text"],
    },
  },
  {
    name: "wait_for_helper",
    description:
      `Wait until a helper finishes its turn and return its reply. Gives up after timeoutSec (default ${DEFAULT_WAIT_SEC}) ` +
      "and reports done: false; call it again to keep waiting.",
    inputSchema: {
      type: "object",
      properties: {
        helperId: text("Id from start_helper."),
        timeoutSec: { type: "number", description: `1–${MAX_WAIT_SEC} seconds.` },
      },
      required: ["helperId"],
    },
  },
  {
    name: "list_helpers",
    description: "Your helpers, their status and the start of their last reply.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "stop_helper",
    description: "Stop what a helper is doing now. It can be messaged again afterwards.",
    inputSchema: { type: "object", properties: { helperId: text("Id from start_helper.") }, required: ["helperId"] },
  },
  {
    name: "helper_diff",
    description: "What an isolated helper changed on its branch so far (uncommitted work included): a summary and the patch.",
    inputSchema: { type: "object", properties: { helperId: text("Id from start_helper.") }, required: ["helperId"] },
  },
  {
    name: "merge_helper",
    description:
      "Merge an isolated helper's branch into your current branch. Wait until it has finished its turn. " +
      "On a conflict nothing is merged and the conflicting files are listed.",
    inputSchema: { type: "object", properties: { helperId: text("Id from start_helper.") }, required: ["helperId"] },
  },
];

// merge_helper changes the lead's files, so the user is still asked about it.
const NAMES = TOOLS.map((tool) => tool.name).filter((name) => name !== "merge_helper").join("|");
/** How adapters title a call to one of these tools: Claude `mcp__kervan__x`, Codex `kervan.x`, Gemini `x (kervan MCP Server)`. */
const TOOL_TITLE = new RegExp(`^(?:(?:mcp__)?kervan(?:__|\\.|/|: ?| )(?:${NAMES})|(?:${NAMES}) \\(kervan MCP Server\\))$`);
const NEVER_AUTO = new Set(["execute", "edit", "delete", "move", "fetch"]);

/**
 * True for a permission request that is only a call to Kervan's own tools. The title is the agent's,
 * so it must match exactly: a shell command that merely mentions a tool name is not one.
 */
export function isOrchestraCall(title: string, toolKind: string): boolean {
  return !NEVER_AUTO.has(toolKind) && TOOL_TITLE.test(title.trim());
}

type Args = Record<string, unknown>;

const str = (args: Args, key: string, required = true): string | undefined => {
  const value = args[key];
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.trim() === "") throw new KervanError("bad_message", `'${key}' must be text`);
  return value;
};

/**
 * Where the socket goes: in the data folder, unless that path is longer than Unix sockets allow (104 bytes on
 * macOS, 108 on Linux); then a short name in the temp folder, the same for the same data folder.
 */
export function orchestraSocketPath(preferred: string): string {
  if (Buffer.byteLength(preferred) <= 100) return preferred;
  const hash = createHash("sha256").update(preferred).digest("hex").slice(0, 12);
  return join(tmpdir(), `kervan-${hash}.sock`);
}

/**
 * Gives lead agents tools to start and talk to helper agents. Each lead gets a small stdio MCP server
 * (orchestra-mcp.ts) that forwards tool calls here over a Unix socket only the kervan user can open.
 * A per-session token tells which lead is calling, so a lead can only reach its own helpers.
 */
export class OrchestraHub {
  private readonly socketPath: string;
  private readonly sessions: SessionManager;
  private readonly server: Server;
  private readonly tokens = new Map<string, string>(); // token → lead session id

  constructor(socketPath: string, sessions: SessionManager) {
    this.socketPath = socketPath;
    this.sessions = sessions;
    this.server = createServer((req, res) => void this.handle(req, res));
  }

  listen(): Promise<void> {
    rmSync(this.socketPath, { force: true }); // left over from a server that didn't shut down cleanly
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen({ path: this.socketPath, readableAll: false, writableAll: false }, () => resolve());
    });
  }

  close(): void {
    this.server.closeAllConnections();
    this.server.close();
    rmSync(this.socketPath, { force: true });
  }

  /** The MCP server to hand a lead agent when it starts. A new token each start; the old one stops working. */
  mcpServer(sessionId: string): acp.McpServer {
    for (const [token, id] of this.tokens) if (id === sessionId) this.tokens.delete(token);
    const token = randomBytes(24).toString("base64url");
    this.tokens.set(token, sessionId);
    return {
      name: ORCHESTRA_MCP_NAME,
      command: process.execPath,
      args: [BRIDGE],
      env: [
        { name: "KERVAN_ORCHESTRA_SOCKET", value: this.socketPath },
        { name: "KERVAN_ORCHESTRA_TOKEN", value: token },
      ],
    };
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    const token = req.headers.authorization?.replace(/^Bearer /, "") ?? "";
    const leadId = this.tokens.get(token);
    if (!leadId) return reply(401, { error: "unauthorized" });

    if (req.method === "GET" && req.url === "/tools") return reply(200, { tools: TOOLS });
    if (req.method !== "POST" || req.url !== "/call") return reply(404, { error: "not_found" });

    let call: { name?: unknown; arguments?: unknown };
    try {
      call = JSON.parse(await readBody(req));
    } catch {
      return reply(400, { error: "bad_json" });
    }
    try {
      const args = (typeof call.arguments === "object" && call.arguments !== null ? call.arguments : {}) as Args;
      const result = await this.call(leadId, String(call.name), args);
      reply(200, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log("info", "orchestra call refused", { leadId, tool: call.name, error: message });
      reply(200, { content: [{ type: "text", text: message }], isError: true });
    }
  }

  private async call(leadId: string, tool: string, args: Args): Promise<unknown> {
    const sessions = this.sessions;
    switch (tool) {
      case "list_agents":
        return sessions.helperChoices();
      case "start_helper":
        return sessions.startHelper(leadId, {
          name: str(args, "name")!,
          task: str(args, "task")!,
          agent: str(args, "agent", false),
          role: str(args, "role", false),
          isolate: args.isolate !== false,
        });
      case "message_helper":
        sessions.messageHelper(leadId, str(args, "helperId")!, str(args, "text")!);
        return { sent: true };
      case "wait_for_helper": {
        const raw = args.timeoutSec === undefined ? DEFAULT_WAIT_SEC : Number(args.timeoutSec);
        const seconds = Number.isFinite(raw) ? Math.min(Math.max(raw, 1), MAX_WAIT_SEC) : DEFAULT_WAIT_SEC;
        return sessions.waitForHelper(leadId, str(args, "helperId")!, seconds * 1000);
      }
      case "list_helpers":
        return sessions.helpers(leadId).map((h): HelperSummary => ({ ...h, reply: h.reply && clip(h.reply, 300) }));
      case "stop_helper":
        await sessions.stopHelper(leadId, str(args, "helperId")!);
        return { stopped: true };
      case "helper_diff":
        return sessions.helperDiff(leadId, str(args, "helperId")!);
      case "merge_helper":
        return sessions.mergeHelper(leadId, str(args, "helperId")!);
      default:
        throw new KervanError("bad_message", `no tool named '${tool}'`);
    }
  }
}

const clip = (value: string, chars: number) => (value.length > chars ? `${value.slice(0, chars - 1)}…` : value);

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}
