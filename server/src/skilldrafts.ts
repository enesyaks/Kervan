import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { stringify } from "yaml";
import { KervanError, type SkillDraft } from "./protocol.ts";
import type { SkillLibrary } from "./skills.ts";

const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_BODY = 20_000;
const MAX_DESCRIPTION = 300;
/** Drafts waiting for the user, on the whole server. */
export const MAX_DRAFTS = 10;
/** Drafts one PM session may write. */
export const MAX_DRAFTS_PER_SESSION = 2;

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/**
 * Skills a PM suggests, waiting for the user. A skill tells every later agent how to do a job, and this text was written
 * by an agent, so it is never used until the user has read it and accepted it; then it becomes an ordinary skill.
 */
export class SkillDrafts {
  private readonly file: string;
  private readonly library: SkillLibrary;
  private drafts: SkillDraft[];

  constructor(file: string, library: SkillLibrary) {
    this.file = file;
    this.library = library;
    this.drafts = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as SkillDraft[]) : [];
  }

  list(): SkillDraft[] {
    return [...this.drafts];
  }

  add(input: Record<string, unknown>, from: { sessionId: string; projectId?: string }): SkillDraft {
    const { name, description, body } = input;
    if (typeof name !== "string" || !NAME.test(name)) bad("a skill's name is lowercase letters, digits or '-'");
    if (this.library.has(name as string)) bad(`the library already has a skill named '${String(name)}'`);
    if (this.drafts.some((d) => d.name === name)) bad(`a skill named '${String(name)}' is already waiting for the user`);
    if (typeof description !== "string" || description.trim() === "" || description.length > MAX_DESCRIPTION) {
      bad(`description must be 1–${MAX_DESCRIPTION} characters: when to use the skill`);
    }
    if (typeof body !== "string" || body.trim() === "" || body.length > MAX_BODY) bad(`body must be 1–${MAX_BODY} characters: how to do the job`);
    if (this.drafts.length >= MAX_DRAFTS) bad(`${MAX_DRAFTS} suggested skills are already waiting for the user; mention this one in your summary instead`);
    if (this.drafts.filter((d) => d.sessionId === from.sessionId).length >= MAX_DRAFTS_PER_SESSION) {
      bad(`you've suggested ${MAX_DRAFTS_PER_SESSION} skills from this card already`);
    }
    const draft: SkillDraft = {
      id: randomUUID(),
      name: name as string,
      description: (description as string).trim(),
      body: (body as string).trim(),
      sessionId: from.sessionId,
      ...(from.projectId ? { projectId: from.projectId } : {}),
      createdAt: new Date().toISOString(),
    };
    this.drafts.push(draft);
    this.persist();
    return draft;
  }

  /** Makes the draft a skill in the library: SKILL.md with its name and description up front. */
  async accept(id: string): Promise<SkillDraft> {
    const draft = this.drafts.find((d) => d.id === id) ?? bad(`no suggested skill '${id}'`);
    if (this.library.has(draft.name)) bad(`the library already has a skill named '${draft.name}'`);
    const dir = this.library.dir(draft.name);
    await mkdir(dir, { recursive: true });
    const front = stringify({ name: draft.name, description: draft.description }).trim();
    await writeFile(join(dir, "SKILL.md"), `---\n${front}\n---\n\n${draft.body}\n`);
    this.drafts = this.drafts.filter((d) => d.id !== id);
    this.persist();
    return draft;
  }

  discard(id: string): void {
    if (!this.drafts.some((d) => d.id === id)) bad(`no suggested skill '${id}'`);
    this.drafts = this.drafts.filter((d) => d.id !== id);
    this.persist();
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.drafts, null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}
