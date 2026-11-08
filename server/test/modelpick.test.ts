import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { Board } from "../src/board.ts";
import { judgeWork, suggestModel } from "../src/modelpick.ts";
import { parseClientMessage, type CardInfo, type ConfigOption } from "../src/protocol.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import { SessionManager } from "../src/sessions.ts";
import { EventStore } from "../src/store.ts";
import { fakeAgent } from "./helpers.ts";

const claude = (value = "default"): ConfigOption[] => [
  { id: "effort", name: "Effort", category: "thought_level", value: "high", choices: [{ value: "high", name: "High" }] },
  {
    id: "model",
    name: "Model",
    category: "model",
    value,
    choices: [
      { value: "default", name: "Default (recommended)", description: "Opus 5.5" },
      { value: "opus", name: "Opus 5.5" },
      { value: "sonnet", name: "Sonnet 5.5" },
      { value: "sonnet-5", name: "Sonnet 5" },
      { value: "haiku-4", name: "Haiku 4.5" },
      { value: "haiku", name: "Haiku 5.5" },
    ],
  },
];

describe("judging a task's size", () => {
  it("reads English and Turkish, with or without accents and in any case", () => {
    assert.equal(judgeWork("Fix a typo", "in the README"), "small");
    assert.equal(judgeWork("Yazım hatası", "Girişteki metni düzelt"), "small");
    assert.equal(judgeWork("GÜVENLİK", "giriş sayfasını gözden geçir"), "large");
    assert.equal(judgeWork("guvenlik", "giris sayfasini gozden gecir"), "large");
  });

  it("lets large work win, and calls what it can't tell medium", () => {
    assert.equal(judgeWork("Small refactor", "of the session manager"), "large");
    assert.equal(judgeWork("Add a dark theme", "to the settings screen"), "medium");
    assert.equal(judgeWork("Fix typo", "x".repeat(401)), "medium");
    assert.equal(judgeWork("Anything", "x".repeat(1501)), "large");
    assert.equal(judgeWork("Anything", "line\n".repeat(30)), "large");
    assert.equal(judgeWork("Fix typo", "in the README", true), "large");
  });
});

describe("suggesting a model", () => {
  it("takes the newest of the cheapest models for small work and the middle one for routine work", () => {
    const small = suggestModel("Fix typo", "in the README", claude())!;
    assert.deepEqual(small, { configId: "model", value: "haiku", name: "Haiku 5.5", defaultName: "Default (recommended)", size: "small" });
    assert.equal(suggestModel("Add a dark theme", "to settings", claude())!.value, "sonnet");
  });

  it("stays with the default for large work", () => {
    assert.equal(suggestModel("Refactor", "the session manager", claude()), undefined);
  });

  it("never suggests the default's own tier or a dearer one", () => {
    assert.equal(suggestModel("Fix typo", "x", claude("haiku")), undefined);
    assert.equal(suggestModel("Add a dark theme", "to settings", claude("sonnet")), undefined);
    assert.equal(suggestModel("Fix typo", "x", claude("sonnet"))!.value, "haiku");
  });

  it("works across agents, and says nothing about models it can't place", () => {
    const options = (value: string, ...names: string[]): ConfigOption[] => [
      { id: "acp:model", name: "Model", category: "model", value, choices: names.map((n) => ({ value: n, name: n })) },
    ];
    assert.equal(suggestModel("Fix typo", "x", options("gemini-2.5-pro", "gemini-2.5-pro", "gemini-2.5-flash"))!.value, "gemini-2.5-flash");
    assert.equal(suggestModel("Fix typo", "x", options("gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash")), undefined);
    // "gemini" has "mini" in it; that doesn't make it a small model.
    assert.equal(suggestModel("Fix typo", "x", options("llama", "llama", "gemini-next")), undefined);
    assert.equal(suggestModel("Fix typo", "x", options("fast", "fast", "smart")), undefined);
    assert.equal(suggestModel("Fix typo", "x", []), undefined);
  });
});

describe("a board card's model", () => {
  const until = async (check: () => boolean) => {
    for (let i = 0; i < 400 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 25));
    assert.ok(check(), "timed out");
  };

  function setup(modelChoiceSeconds = 60) {
    const tiered = { ...fakeAgent, name: "Kademeli", args: [...fakeAgent.args, "--tiered"] };
    const dir = mkdtempSync(join(tmpdir(), "kervan-modelpick-"));
    const sessions = new SessionManager(new LocalAcpRunner(), new Map([["tiered", tiered]]), dir, new EventStore(":memory:"));
    const board = new Board(join(dir, "board.json"), {
      hasProject: () => true,
      hasAgent: () => true,
      start: (card, _files, choose) => sessions.runTask({ agent: card.agent, title: card.title, prompt: card.prompt, choose }),
      session: (id) => sessions.list().find((s) => s.id === id),
      broadcast: () => {},
      modelChoiceSeconds,
    });
    const newCard = (title = "Fix typo", prompt = "modelcheck") => board.save({ projectId: "p", title, prompt, agent: "tiered" });
    const reply = (card: CardInfo) => sessions.history(card.sessionId!).flatMap((e) => (e.kind === "agent_message_chunk" ? [e.text] : [])).at(-1);
    return { sessions, board, newCard, reply };
  }

  it("holds the prompt until the suggestion is accepted, then runs on that model", async (t) => {
    const { sessions, board, newCard, reply } = setup();
    t.after(() => sessions.closeAll());
    const card = newCard();
    const moved = board.move(card.id, "working");
    await until(() => card.modelChoice !== undefined);
    assert.deepEqual(card.modelChoice, { model: "Haiku 5.5", defaultModel: "Default (recommended)", size: "small", waitSeconds: 60 });
    assert.equal(sessions.history(sessions.list()[0].id).some((e) => e.kind === "user_message"), false);

    // While it waits it can't be moved, started twice or reworded.
    await assert.rejects(board.move(card.id, "working"), /waiting for its model/);
    assert.throws(() => board.save({ id: card.id, title: "x", prompt: "y", agent: "tiered" }), /waiting for its model/);

    board.answerModel(card.id, false);
    await moved;
    assert.equal(card.modelChoice, undefined);
    await until(() => reply(card) === "model: haiku");
  });

  it("stays on the default when the user asks for it", async (t) => {
    const { sessions, board, newCard, reply } = setup();
    t.after(() => sessions.closeAll());
    const card = newCard();
    const moved = board.move(card.id, "working");
    await until(() => card.modelChoice !== undefined);
    board.answerModel(card.id, true);
    await moved;
    await until(() => reply(card) === "model: default");
  });

  it("goes on with the suggestion when nobody answers", async (t) => {
    const { sessions, board, newCard, reply } = setup(0.05);
    t.after(() => sessions.closeAll());
    const card = newCard();
    await board.move(card.id, "working");
    assert.equal(card.modelChoice, undefined);
    await until(() => reply(card) === "model: haiku");
    board.answerModel(card.id, true); // too late: nothing left to change
  });

  it("asks nothing when the work needs the default anyway", async (t) => {
    const { sessions, board, newCard, reply } = setup();
    t.after(() => sessions.closeAll());
    const card = newCard("Refactor the sessions", "modelcheck");
    await board.move(card.id, "working");
    await until(() => reply(card) === "model: default");
  });

  it("drops the session without prompting it when the card is deleted while it waits", async (t) => {
    const { sessions, board, newCard } = setup();
    t.after(() => sessions.closeAll());
    const card = newCard();
    const moved = board.move(card.id, "working");
    await until(() => card.modelChoice !== undefined);
    board.remove(card.id);
    await moved;
    const [session] = sessions.list();
    assert.equal(session.archived, true);
    assert.equal(sessions.history(session.id).some((e) => e.kind === "user_message"), false);
  });

  it("puts a card that was waiting back in To do after a restart", () => {
    const file = join(mkdtempSync(join(tmpdir(), "kervan-modelpick-")), "board.json");
    const stored = {
      id: "c", projectId: "p", title: "t", prompt: "x", agent: "a", column: "working", createdAt: "a", updatedAt: "b",
      modelChoice: { model: "Haiku 5.5", defaultModel: "Opus 5.5", size: "small", waitSeconds: 15 },
    };
    writeFileSync(file, JSON.stringify([stored]));
    const board = new Board(file, { hasProject: () => true, hasAgent: () => true, start: async () => "", session: () => undefined, broadcast: () => {} });
    const [card] = board.list("p");
    assert.equal(card.column, "todo");
    assert.equal(card.modelChoice, undefined);
  });

  it("needs a real answer on the wire", () => {
    assert.equal(parseClientMessage(JSON.stringify({ type: "card.model", id: "1", cardId: "c", useDefault: true })).ok, true);
    assert.equal(parseClientMessage(JSON.stringify({ type: "card.model", id: "1", cardId: "c" })).ok, false);
    assert.equal(parseClientMessage(JSON.stringify({ type: "card.model", id: "1", cardId: "c", useDefault: "yes" })).ok, false);
  });
});
