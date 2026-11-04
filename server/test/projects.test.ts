import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { after, before, describe, it } from "node:test";
import { ProjectRegistry, slug } from "../src/projects.ts";

describe("project folders", () => {
  let dir: string;
  let root: string;
  let projects: ProjectRegistry;
  before(() => {
    dir = mkdtempSync(join(tmpdir(), "kervan-projects-"));
    root = join(dir, "root");
    projects = new ProjectRegistry(join(dir, "projects.json"), root);
  });
  after(() => rmSync(dir, { recursive: true, force: true }));

  const refusal = (input: Record<string, unknown>, pattern: RegExp) =>
    assert.rejects(projects.save(input), (error: Error & { code?: string }) => {
      assert.equal(error.code, "bad_message");
      assert.match(error.message, pattern);
      return true;
    });

  it("takes only network addresses to clone, and clones nothing else", async () => {
    for (const gitUrl of ["file:///etc", "/etc", "../up", "ext::sh -c touch${IFS}pwned", "--upload-pack=touch pwned", "http://plain.example/x.git", "https://has space/x.git", "git@:x", "https://a/x\n--evil"]) {
      await refusal({ name: "clone", gitUrl }, /gitUrl must be/);
    }
    assert.deepEqual(existsSync(root) ? readdirSync(root) : [], []);
  });

  it("says why a clone failed", async () => {
    await refusal({ name: "gone", gitUrl: "https://127.0.0.1:1/x.git" }, /couldn't clone https:\/\/127\.0\.0\.1:1\/x\.git: \S/);
  });

  it("only takes an existing folder given by its full path", async () => {
    const file = join(dir, "a-file");
    writeFileSync(file, "");
    await refusal({ name: "x", path: "relative/folder" }, /absolute path/);
    await refusal({ name: "x", path: join(dir, "missing") }, /no folder at/);
    await refusal({ name: "x", path: file }, /no folder at/);
  });

  it("refuses a bad name or instructions", async () => {
    await refusal({ name: "   " }, /needs a name/);
    await refusal({ name: 42 }, /needs a name/);
    await refusal({ name: "x".repeat(81) }, /needs a name/);
    await refusal({ name: "x", instructions: "y".repeat(20_001) }, /instructions must be/);
    await refusal({ name: "x", instructions: 42 }, /instructions must be/);
  });

  it("uses an existing folder as it is, and normalizes its path", async () => {
    const folder = join(dir, "existing");
    mkdirSync(folder);
    const project = await projects.save({ name: "Var", path: join(folder, "sub", "..") });
    assert.equal(project.path, folder);
  });

  it("gives projects of the same name folders of their own", async () => {
    const first = await projects.save({ name: "Çok Güzel Proje" });
    const second = await projects.save({ name: "Çok Güzel Proje" });
    assert.equal(basename(first.path), "cok-guzel-proje");
    assert.notEqual(first.path, second.path);
    assert.ok(existsSync(first.path) && existsSync(second.path));
  });

  it("can't move an existing project to another folder", async () => {
    const project = await projects.save({ name: "Sabit" });
    const updated = await projects.save({ id: project.id, name: " Yeni ad ", instructions: " talimat ", path: "/etc", gitUrl: "https://x/y.git" });
    assert.equal(updated.path, project.path);
    assert.equal(updated.name, "Yeni ad");
    assert.equal(updated.instructions, "talimat");
    await refusal({ id: "missing", name: "x" }, /no project 'missing'/);
    await refusal({ id: 7, name: "x" }, /no project '7'/);
  });

  it("keeps projects over a restart", async () => {
    const project = await projects.save({ name: "Kalıcı" });
    const reopened = new ProjectRegistry(join(dir, "projects.json"), root);
    assert.deepEqual(reopened.get(project.id), project);
  });

  it("makes a folder name from anything", () => {
    assert.equal(slug("İstanbul Şehri"), "istanbul-sehri");
    assert.equal(slug("!!!"), "project");
    assert.equal(slug("x".repeat(60)).length, 48);
  });
});
