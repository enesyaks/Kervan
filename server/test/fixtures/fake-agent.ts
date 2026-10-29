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
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const stream = acp.ndJsonStream(
  Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
  Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
);

let current = "";
let authenticated = "none";
let mcpNames: string[] = [];

acp
  .agent({ name: "fake" })
  .onRequest("initialize", () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: { sessionCapabilities: { resume: {} } },
    authMethods: [{ id: "fake-key", name: "Fake key" }],
  }))
  .onRequest("authenticate", ({ params }) => {
    authenticated = params.methodId;
    return {};
  })
  .onRequest("session/new", ({ params }) => {
    mcpNames = params.mcpServers.map((server) => server.name);
    current = `fake-${process.pid}`;
    return { sessionId: current };
  })
  .onRequest("session/resume", ({ params }) => {
    mcpNames = (params.mcpServers ?? []).map((server) => server.name);
    current = params.sessionId;
    return {};
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
