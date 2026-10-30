import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { ServerMessage, SessionEvent } from "../src/protocol.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import { SessionManager } from "../src/sessions.ts";
import { EventStore } from "../src/store.ts";
import { fakeAgent } from "./helpers.ts";

/** One "server process": a manager over a store file that outlives it. */
function boot(dir: string) {
  const store = new EventStore(join(dir, "kervan.db"));
  const sessions = new SessionManager(new LocalAcpRunner(), new Map([["fake", fakeAgent]]), join(dir, "ws"), store);
  const seen: ServerMessage[] = [];
  sessions.subscribe((m) => seen.push(m));
  const until = (match: (m: ServerMessage) => boolean, timeoutMs = 5000) =>
    new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out")), timeoutMs);
      const check = () => (seen.some(match) ? (clearTimeout(timer), resolve()) : setTimeout(check, 10));
      check();
    });
  const shutdown = () => {
    sessions.closeAll();
    store.close();
  };
  return { sessions, until, shutdown };
}

const isStatus = (id: string, status: string) => (m: ServerMessage) =>
  m.type === "session.updated" && m.session.id === id && m.session.status === status;
const isEvent = (id: string, kind: string) => (m: ServerMessage) =>
  m.type === "session.event" && m.sessionId === id && m.event.kind === kind;
const texts = (events: SessionEvent[]) => events.flatMap((e) => (e.kind === "agent_message_chunk" ? [e.text] : []));

describe("server restart", () => {
  it("keeps history and resumes the same agent conversation", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-restart-"));

    const first = boot(dir);
    const { id } = await first.sessions.create("fake");
    await first.until(isStatus(id, "idle"));
    first.sessions.prompt(id, "whoami");
    await first.until(isEvent(id, "turn_end"));
    const agentSessionId = texts(first.sessions.history(id))[0];
    first.shutdown();

    const second = boot(dir);
    assert.equal(second.sessions.list()[0].status, "idle");
    // The agent announces its slash commands whenever it likes; they aren't part of the turn.
    assert.deepEqual(
      second.sessions.history(id).map((e) => e.kind).filter((kind) => kind !== "commands"),
      ["user_message", "agent_message_chunk", "turn_end"],
    );

    second.sessions.prompt(id, "whoami again");
    await second.until((m) => isEvent(id, "turn_end")(m));
    const history = second.sessions.history(id);
    assert.ok(history.some((e) => e.kind === "notice"), "tells the user the agent was resumed");
    assert.equal(texts(history).at(-1), agentSessionId, "the resumed agent continues the same ACP session");
    second.shutdown();
  });

  it("closes a turn and its permission request that were cut off", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-restart-"));

    const first = boot(dir);
    const { id } = await first.sessions.create("fake");
    await first.until(isStatus(id, "idle"));
    first.sessions.prompt(id, "use a tool");
    await first.until(isStatus(id, "waiting"));
    first.shutdown();

    const second = boot(dir);
    const tail = second.sessions.history(id).slice(-2);
    assert.equal(tail[0].kind, "permission_resolved");
    assert.equal(tail[0].kind === "permission_resolved" && tail[0].outcome, "cancelled");
    assert.equal(tail[1].kind === "turn_end" && tail[1].stopReason, "interrupted");
    assert.equal(second.sessions.list()[0].status, "idle");
    second.shutdown();
  });
});
