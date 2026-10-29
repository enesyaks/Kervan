// A tiny ACP agent for tests. Behaviour is driven by the prompt text:
//   default  → echoes "echo: <text>" in two chunks
//   "tool"   → also reports a tool call, asks for permission, then fails the tool
//   "slow"   → waits 300 ms before answering
//   "crash"  → exits mid-turn
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const stream = acp.ndJsonStream(
  Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
  Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
);

acp
  .agent({ name: "fake" })
  .onRequest("initialize", () => ({ protocolVersion: acp.PROTOCOL_VERSION }))
  .onRequest("session/new", () => ({ sessionId: "fake-session" }))
  .onRequest("session/prompt", async ({ params, client }) => {
    const text = params.prompt.map((block) => (block.type === "text" ? block.text : "")).join("");
    const update = (u: acp.SessionUpdate) => client.notify("session/update", { sessionId: params.sessionId, update: u });

    if (text.includes("crash")) process.exit(1);
    if (text.includes("slow")) await new Promise((resolve) => setTimeout(resolve, 300));

    await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "echo: " } });
    await update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

    if (text.includes("tool")) {
      await update({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Edit README.md", kind: "edit", status: "pending" });
      const answer = await client.request("session/request_permission", {
        sessionId: params.sessionId,
        toolCall: { toolCallId: "t1", title: "Edit README.md" },
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
