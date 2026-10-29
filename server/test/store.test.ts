import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { EventStore } from "../src/store.ts";

const info = { id: "s1", agent: "claude", title: "Yeni oturum", status: "idle" as const, createdAt: "2026-10-29T10:00:00.000Z" };

describe("EventStore", () => {
  it("round-trips sessions and events across reopening the file", () => {
    const path = join(mkdtempSync(join(tmpdir(), "kervan-store-")), "kervan.db");
    const store = new EventStore(path);
    store.saveSession({ info, agentSessionId: "acp-1" });
    store.appendEvent("s1", { kind: "user_message", text: "merhaba", seq: 1, at: "t1" });
    store.appendEvent("s1", { kind: "turn_end", stopReason: "end_turn", seq: 2, at: "t2" });
    store.close();

    const reopened = new EventStore(path);
    assert.deepEqual(reopened.loadSessions(), [{ info, agentSessionId: "acp-1" }]);
    assert.deepEqual(reopened.loadEvents("s1"), [
      { kind: "user_message", text: "merhaba", seq: 1, at: "t1" },
      { kind: "turn_end", stopReason: "end_turn", seq: 2, at: "t2" },
    ]);
    reopened.close();
  });

  it("updates a session without losing its agent session id", () => {
    const store = new EventStore(":memory:");
    store.saveSession({ info, agentSessionId: "acp-1" });
    store.saveSession({ info: { ...info, title: "Başlık", status: "error", error: "boom" } });
    assert.deepEqual(store.loadSessions(), [
      { info: { ...info, title: "Başlık", status: "error", error: "boom" }, agentSessionId: "acp-1" },
    ]);
  });

  it("refuses a duplicate seq", () => {
    const store = new EventStore(":memory:");
    store.saveSession({ info });
    store.appendEvent("s1", { kind: "error", message: "a", seq: 1, at: "t" });
    assert.throws(() => store.appendEvent("s1", { kind: "error", message: "b", seq: 1, at: "t" }));
  });
});
