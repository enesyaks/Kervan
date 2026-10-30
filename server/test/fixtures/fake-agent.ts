// A tiny ACP agent for tests. Behaviour is driven by the prompt text:
//   default  → echoes "echo: <text>" in two chunks
//   "tool"   → also reports a tool call and asks for permission; completes the tool only if allowed
//   "slow"   → waits 300 ms before answering
//   "crash"  → exits mid-turn
//   attached files → answers "files: <file:// uris>"
//   "mcpcheck" → names of the MCP servers it was given
//   "prefacecheck" → the hidden text block sent before the user's text, or "no preface"
//   "authstate" → answers with the auth method chosen via `authenticate`, or "none"
//   "whoami" → answers with the ACP session id it is running (new or resumed)
//   "delegate: <task>" → starts a helper through the `kervan` MCP server, waits, answers "helper said: <reply>"
//   "askperm: <kind> <title>" → asks permission for that tool call, answers "permission: <optionId or cancelled>"
//   "usage <usd>" → reports a usage update with that cumulative cost
//   "modelcheck" → the model currently chosen (session setting "model": fast | smart)
//   with --legacy, models and modes come the older way (session/new `models` and `modes`, session/set_model,
//   session/set_mode), as Gemini CLI does, instead of config options; "modecheck" → the current mode
//   "mcptools" → names of the tools the `kervan` MCP server offers
//   "write <name> <text>" → writes the file in its folder, reports a plan and the edit as a diff
//   "imagecheck" → the MIME types of the image blocks it was given
//   right after session/new it announces two slash commands (review, explain)
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const stream = acp.ndJsonStream(
  Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
  Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
);

let current = "";
let cwd = process.cwd();
let authenticated = "none";
let mcpNames: string[] = [];
let mcpServers: acp.McpServer[] = [];
let model = "fast";
let mode = "default";
const legacy = process.argv.includes("--legacy");
const legacyState = () => ({
  models: {
    currentModelId: model,
    availableModels: [
      { modelId: "fast", name: "Hızlı" },
      { modelId: "smart", name: "Akıllı", description: "Daha yavaş" },
    ],
  },
  modes: {
    currentModeId: mode,
    availableModes: [
      { id: "default", name: "Varsayılan" },
      { id: "yolo", name: "Her şeye izin ver" },
    ],
  },
});
const configOptions = (): acp.SessionConfigOption[] => [
  {
    type: "select",
    id: "model",
    name: "Model",
    category: "model",
    currentValue: model,
    options: [
      { group: "small", name: "Küçük", options: [{ value: "fast", name: "Hızlı" }] },
      { group: "big", name: "Büyük", options: [{ value: "smart", name: "Akıllı", description: "Daha yavaş" }] },
    ],
  },
  { type: "boolean", id: "beta", name: "Beta", currentValue: false },
];

/** A bare MCP client: starts the named stdio server and returns a function that calls one method on it. */
async function mcpClient(name: string): Promise<(method: string, params?: object) => Promise<any>> {
  const server = mcpServers.find((s) => s.name === name) as acp.McpServerStdio | undefined;
  if (!server) throw new Error(`no MCP server '${name}'`);
  const child = spawn(server.command, server.args, {
    env: { ...process.env, ...Object.fromEntries(server.env.map((e) => [e.name, e.value])) },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const waiting = new Map<number, (result: any) => void>();
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const message = JSON.parse(line);
    waiting.get(message.id)?.(message.result ?? message.error);
  });
  let next = 0;
  const call = (method: string, params: object = {}) =>
    new Promise<any>((resolve) => {
      const id = ++next;
      waiting.set(id, resolve);
      child.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fake", version: "0" } });
  child.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  process.on("exit", () => child.kill());
  return call;
}

acp
  .agent({ name: "fake" })
  .onRequest("initialize", () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: { sessionCapabilities: { resume: {} }, promptCapabilities: { image: true } },
    authMethods: [{ id: "fake-key", name: "Fake key" }],
  }))
  .onRequest("authenticate", ({ params }) => {
    authenticated = params.methodId;
    return {};
  })
  .onRequest("session/new", ({ params, client }) => {
    cwd = params.cwd;
    // Agents announce their slash commands right after the session starts.
    setTimeout(() => {
      void client.notify("session/update", {
        sessionId: current,
        update: {
          sessionUpdate: "available_commands_update",
          availableCommands: [
            { name: "review", description: "Review the changes" },
            { name: "explain", description: "Explain code", input: { hint: "file or symbol" } },
          ],
        },
      });
    }, 20);
    mcpServers = params.mcpServers;
    mcpNames = params.mcpServers.map((server) => server.name);
    current = `fake-${process.pid}`;
    return legacy ? { sessionId: current, ...legacyState() } : { sessionId: current, configOptions: configOptions() };
  })
  .onRequest("session/resume", ({ params }) => {
    cwd = params.cwd;
    mcpServers = params.mcpServers ?? [];
    mcpNames = mcpServers.map((server) => server.name);
    current = params.sessionId;
    return legacy ? legacyState() : { configOptions: configOptions() };
  })
  // Not in the stable schema; Gemini CLI still answers it.
  .onRequest("session/set_model", { parse: (value: unknown) => value as { modelId: string } }, ({ params }) => {
    model = params.modelId;
    return {};
  })
  .onRequest("session/set_mode", ({ params }) => {
    mode = params.modeId;
    return {};
  })
  .onRequest("session/set_config_option", ({ params }) => {
    if (params.configId === "model" && typeof params.value === "string") model = params.value;
    return { configOptions: configOptions() };
  })
  .onRequest("session/prompt", async ({ params, client }) => {
    const texts = params.prompt.flatMap((block) => (block.type === "text" ? [block.text] : []));
    const text = texts.at(-1) ?? "";
    const update = (u: acp.SessionUpdate) => client.notify("session/update", { sessionId: params.sessionId, update: u });

    if (text.includes("crash")) process.exit(1);
    if (text.includes("mcpcheck")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `mcp: ${mcpNames.join(",")}` } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("modecheck")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `mode: ${mode}` } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("modelcheck")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `model: ${model}` } });
      return { stopReason: "end_turn" };
    }
    if (text.startsWith("usage ")) {
      await update({ sessionUpdate: "usage_update", used: 1200, size: 200_000, cost: { amount: Number(text.slice(6)), currency: "USD" } });
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "spent" } });
      return { stopReason: "end_turn" };
    }
    if (text.startsWith("askperm: ")) {
      const [kind, ...rest] = text.slice("askperm: ".length).split(" ");
      const answer = await client.request("session/request_permission", {
        sessionId: params.sessionId,
        toolCall: { toolCallId: "p1", title: rest.join(" "), kind: kind as acp.ToolKind },
        options: [
          { optionId: "yes", name: "Allow", kind: "allow_once" },
          { optionId: "no", name: "Reject", kind: "reject_once" },
        ],
      });
      const chosen = answer.outcome.outcome === "selected" ? answer.outcome.optionId : "cancelled";
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `permission: ${chosen}` } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("mcptools")) {
      const call = await mcpClient("kervan");
      const { tools } = await call("tools/list");
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: tools.map((t: any) => t.name).join(",") } });
      return { stopReason: "end_turn" };
    }
    if (text.startsWith("delegate: ")) {
      const call = await mcpClient("kervan");
      const tool = async (name: string, args: object) => {
        const result = await call("tools/call", { name, arguments: args });
        if (result.isError) throw new Error(result.content[0].text);
        return JSON.parse(result.content[0].text);
      };
      try {
        const { agents } = await tool("list_agents", {});
        const { helperId } = await tool("start_helper", { agent: agents[0].id, name: "Yardımcı", task: text.slice("delegate: ".length) });
        let summary = await tool("wait_for_helper", { helperId, timeoutSec: 20 });
        while (!summary.done) summary = await tool("wait_for_helper", { helperId, timeoutSec: 20 });
        await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `helper said: ${summary.reply}` } });
      } catch (error) {
        await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `refused: ${(error as Error).message}` } });
      }
      return { stopReason: "end_turn" };
    }
    if (text.includes("prefacecheck")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: texts.length > 1 ? texts[0] : "no preface" } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("authstate")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: authenticated } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("whoami")) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: current } });
      return { stopReason: "end_turn" };
    }
    if (text.startsWith("write ")) {
      const [name, ...content] = text.slice("write ".length).split(" ");
      const path = join(cwd, name);
      const oldText = existsSync(path) ? readFileSync(path, "utf8") : null;
      writeFileSync(path, content.join(" "));
      await update({
        sessionUpdate: "plan",
        entries: [
          { content: `Write ${name}`, status: "completed", priority: "high" },
          { content: "Report back", status: "in_progress", priority: "low" },
        ],
      });
      await update({
        sessionUpdate: "tool_call",
        toolCallId: `w-${name}`,
        title: `Write ${name}`,
        kind: "edit",
        status: "completed",
        content: [{ type: "diff", path, oldText, newText: content.join(" ") }],
      });
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `wrote ${name}` } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("imagecheck")) {
      const images = params.prompt.filter((block) => block.type === "image");
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `images: ${images.map((i) => (i as acp.ImageContent).mimeType).join(",")}` } });
      return { stopReason: "end_turn" };
    }
    if (text.includes("slow")) await new Promise((resolve) => setTimeout(resolve, 300));

    const links = params.prompt.flatMap((block) => (block.type === "resource_link" ? [block.uri] : []));
    if (links.length > 0) {
      await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `files: ${links.join(",")}` } });
      return { stopReason: "end_turn" };
    }

    await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "echo: " } });
    await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

    if (text.includes("tool")) {
      await update({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Edit README.md", kind: "edit", status: "pending" });
      const answer = await client.request("session/request_permission", {
        sessionId: params.sessionId,
        toolCall: { toolCallId: "t1", title: "Edit README.md", kind: "edit", rawInput: { command: "sed -i s/a/b/ README.md" } },
        options: [
          { optionId: "yes", name: "Allow", kind: "allow_once" },
          { optionId: "no", name: "Reject", kind: "reject_once" },
        ],
      });
      const allowed = answer.outcome.outcome === "selected" && answer.outcome.optionId === "yes";
      await update({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: allowed ? "completed" : "failed" });
    }
    return { stopReason: "end_turn" };
  })
  .connect(stream);
