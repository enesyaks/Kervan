import assert from "node:assert/strict";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { EventStore } from "../src/store.ts";

const info = { id: "s1", agent: "claude", title: "Yeni oturum", status: "idle" as const, createdAt: "2026-10-29T10:00:00.000Z", archived: false, skills: [], mcpServers: [] };

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

  it("keeps which lead a helper belongs to and which sessions may start helpers", () => {
    const store = new EventStore(":memory:");
    store.saveSession({ info: { ...info, orchestrate: true } });
    store.saveSession({ info: { ...info, id: "s2", parentId: "s1" } });
    assert.deepEqual(store.loadSessions().map((s) => s.info), [{ ...info, orchestrate: true }, { ...info, id: "s2", parentId: "s1" }]);
  });

  it("keeps budgets, branches and the latest usage", () => {
    const store = new EventStore(":memory:");
    const usage = { contextUsed: 10, contextSize: 100, costUsd: 0.12 };
    store.saveSession({ info: { ...info, orchestrate: true, budgetUsd: 2 } });
    store.saveSession({ info: { ...info, id: "s2", parentId: "s1", branch: "kervan/a-1" } });
    const config = [{ id: "model", name: "Model", value: "opus", choices: [{ value: "opus", name: "Opus" }] }];
    store.saveSession({ info: { ...info, orchestrate: true, budgetUsd: 2, usage, config } });
    assert.deepEqual(store.loadSessions().map((s) => s.info), [
      { ...info, orchestrate: true, budgetUsd: 2, usage, config },
      { ...info, id: "s2", parentId: "s1", branch: "kervan/a-1" },
    ]);
  });

  it("backs up once a day and keeps the newest copies", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-backup-"));
    const store = new EventStore(join(dir, "kervan.db"));
    store.saveSession({ info });
    const backups = join(dir, "backups");
    for (const day of ["01", "02", "03", "04"]) store.backup(backups, 2, new Date(`2026-10-${day}T12:00:00Z`));
    assert.equal(store.backup(backups, 2, new Date("2026-10-04T18:00:00Z")), undefined, "one a day");
    assert.deepEqual(readdirSync(backups).sort(), ["kervan-2026-10-03.db", "kervan-2026-10-04.db"]);
    const copy = new EventStore(join(backups, "kervan-2026-10-04.db"));
    assert.deepEqual(copy.loadSessions().map((s) => s.info.id), ["s1"]);
  });

  it("refuses a duplicate seq", () => {
    const store = new EventStore(":memory:");
    store.saveSession({ info });
    store.appendEvent("s1", { kind: "error", message: "a", seq: 1, at: "t" });
    assert.throws(() => store.appendEvent("s1", { kind: "error", message: "b", seq: 1, at: "t" }));
  });
});

describe("search", () => {
  const event = (seq: number, body: Record<string, unknown>) => ({ ...body, seq, at: `t${seq}` }) as never;

  it("finds words split across streamed chunks, ignoring Turkish diacritics", () => {
    const store = new EventStore(":memory:");
    store.saveSession({ info });
    store.indexMessage("s1", { seq: 1, role: "user", text: "Şubat raporunu hazırla" });
    store.indexMessage("s1", { seq: 2, role: "agent", text: "Rap" });
    store.indexMessage("s1", { seq: 2, role: "agent", text: "Rapor hazır, Kervan yolda." });

    assert.deepEqual(store.search("subat").map((h) => [h.seq, h.role]), [[1, "user"]]);
    const agentHits = store.search("rapor hazir");
    assert.deepEqual(agentHits.map((h) => h.seq).sort(), [1, 2], "prefix match on both, the streamed one replaced not duplicated");
    assert.match(store.search("kervan")[0].snippet, /\u0001Kervan\u0002/);
    assert.deepEqual(store.search("kervan zebra"), [], "every word must match");
    assert.deepEqual(store.search('"  '), []);
  });

  it("upgrades an M3 database and backfills the index from stored events", async () => {
    const { DatabaseSync } = await import("node:sqlite");
    const path = join(mkdtempSync(join(tmpdir(), "kervan-migrate-")), "kervan.db");
    const old = new DatabaseSync(path);
    old.exec(`
      CREATE TABLE sessions (id TEXT PRIMARY KEY, agent TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL,
        created_at TEXT NOT NULL, error TEXT, agent_session_id TEXT);
      CREATE TABLE events (session_id TEXT NOT NULL, seq INTEGER NOT NULL, at TEXT NOT NULL, body TEXT NOT NULL,
        PRIMARY KEY (session_id, seq));
      INSERT INTO sessions VALUES ('s1', 'claude', 'Eski', 'idle', '2026-10-29T08:00:00Z', NULL, 'acp-1');
      INSERT INTO events VALUES ('s1', 1, 't1', '{"kind":"user_message","text":"gizli kelime"}');
      INSERT INTO events VALUES ('s1', 2, 't2', '{"kind":"agent_message_chunk","text":"la"}');
      INSERT INTO events VALUES ('s1', 3, 't3', '{"kind":"agent_message_chunk","text":"pis"}');
      INSERT INTO events VALUES ('s1', 4, 't4', '{"kind":"turn_end","stopReason":"end_turn"}');
    `);
    old.close();

    const store = new EventStore(path);
    assert.equal(store.loadSessions()[0].info.archived, false);
    assert.deepEqual(store.search("lapis").map((h) => [h.seq, h.role]), [[2, "agent"]]);
    store.close();

    const again = new EventStore(path);
    assert.equal(again.search("lapis").length, 1, "migration runs once");
    again.close();
  });

  it("folds events into whole messages", async () => {
    const { foldMessages } = await import("../src/store.ts");
    assert.deepEqual(
      foldMessages([
        event(1, { kind: "user_message", text: "a" }),
        event(2, { kind: "agent_message_chunk", text: "b" }),
        event(3, { kind: "agent_thought_chunk", text: "…" }),
        event(4, { kind: "agent_message_chunk", text: "c" }),
        event(5, { kind: "tool_call", toolCallId: "t", title: "x", toolKind: "read", status: "pending" }),
        event(6, { kind: "agent_message_chunk", text: "d" }),
      ]),
      [
        { seq: 1, role: "user", text: "a" },
        { seq: 2, role: "agent", text: "bc" },
        { seq: 6, role: "agent", text: "d" },
      ],
    );
  });
});

describe("Turkish folding", () => {
  it("keeps length and maps ı, İ and diacritics to plain letters", async () => {
    const { foldText, makeSnippet } = await import("../src/store.ts");
    const text = "İpek Yolu'nda ŞUBAT ayı, Çay ve Gül";
    assert.equal(foldText(text), "ipek yolu'nda subat ayi, cay ve gul");
    assert.equal(foldText(text).length, text.length);
    assert.equal(makeSnippet(text, ["subat", "ayi"]), "İpek Yolu'nda \u0001ŞUBAT\u0002 \u0001ayı\u0002, Çay ve Gül");
  });
});
