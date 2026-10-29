import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type { SessionManager } from "../src/sessions.ts";
import { skillDescription } from "../src/skills.ts";
import { TEST_TOKEN, startServer } from "./helpers.ts";

const SKILL_MD = `---
name: rapor
description: Şirket raporlarını standart şablonla hazırlar.
---
# Rapor
Önce templates/rapor.md dosyasını oku.
`;

describe("skill library", () => {
  let base = "";
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  const auth = { authorization: `Bearer ${TEST_TOKEN}` };
  const put = (path: string, body: string) => fetch(`${base}/v1/skills/${path}`, { method: "PUT", headers: auth, body });
  const list = async () => (await (await fetch(`${base}/v1/skills`, { headers: auth })).json()).skills;

  before(async () => {
    const started = await startServer();
    base = `http://127.0.0.1:${started.port}`;
    sessions = started.sessions;
    stop = started.stop;
  });

  after(() => stop());

  it("reads the description from SKILL.md front matter", () => {
    assert.equal(skillDescription(SKILL_MD), "Şirket raporlarını standart şablonla hazırlar.");
    assert.equal(skillDescription("# no front matter"), "");
  });

  it("lists a skill only once its SKILL.md is uploaded", async () => {
    assert.equal((await put("rapor/templates/rapor.md", "# Şablon")).status, 201);
    assert.deepEqual(await list(), [], "half-uploaded skill is not offered");
    assert.equal((await put("rapor/SKILL.md", SKILL_MD)).status, 201);
    assert.deepEqual(await list(), [{ name: "rapor", description: "Şirket raporlarını standart şablonla hazırlar.", files: 2 }]);
  });

  it("refuses bad names and paths, and requires the token", async () => {
    assert.equal((await put("Rapor/SKILL.md", SKILL_MD)).status, 400);
    assert.equal((await put("rapor/..%2F..%2Fescape.md", "x")).status, 400);
    assert.equal((await fetch(`${base}/v1/skills`)).status, 401);
  });

  it("copies chosen skills into the agent's folder and tells the agent once", async () => {
    const { id } = await sessions.create("fake", ["rapor"]);
    const cwd = sessions.workspace(id);
    assert.equal(readFileSync(join(cwd, ".fake/skills/rapor/SKILL.md"), "utf8"), SKILL_MD);
    assert.ok(existsSync(join(cwd, ".fake/skills/rapor/templates/rapor.md")));
    assert.deepEqual(sessions.list().find((s) => s.id === id)?.skills, ["rapor"]);

    await waitIdle(sessions, id);
    sessions.prompt(id, "prefacecheck");
    const first = await nextReply(sessions, id);
    assert.match(first, /Agent Skills available/);
    assert.match(first, /- rapor: Şirket raporlarını .* instructions: \.fake\/skills\/rapor\/SKILL\.md/);

    await waitIdle(sessions, id);
    sessions.prompt(id, "prefacecheck");
    assert.equal(await nextReply(sessions, id), "no preface", "only the first message carries it");
  });

  it("rejects unknown skills and removes skills", async () => {
    await assert.rejects(sessions.create("fake", ["yok"]), /no skill named 'yok'/);
    assert.equal((await fetch(`${base}/v1/skills/rapor`, { method: "DELETE", headers: auth })).status, 204);
    assert.deepEqual(await list(), []);
  });
});

async function waitIdle(sessions: SessionManager, id: string): Promise<void> {
  for (let i = 0; i < 200; i++) {
    if (sessions.list().find((s) => s.id === id)?.status === "idle") return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("session never became idle");
}

/** The agent text of the latest finished turn. */
async function nextReply(sessions: SessionManager, id: string): Promise<string> {
  const start = sessions.history(id).length;
  for (let i = 0; i < 300; i++) {
    const events = sessions.history(id).slice(start);
    if (events.some((e) => e.kind === "turn_end")) {
      return events.flatMap((e) => (e.kind === "agent_message_chunk" ? [e.text] : [])).join("");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("turn never ended");
}
