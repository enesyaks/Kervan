import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { commitAll } from "../src/checkpoints.ts";
import { openPullRequest } from "../src/pullrequest.ts";
import { assertSafeRepository, refusedSetting } from "../src/safegit.ts";
import { addWorktree } from "../src/worktree.ts";

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", ["-C", cwd, "-c", "user.name=T", "-c", "user.email=t@t", ...args], { stdio: ["ignore", "pipe", "pipe"] }).toString().trim();

/** A repository with one commit, and a marker path a planted command would create. */
function repository(): { dir: string; marker: string } {
  const root = mkdtempSync(join(tmpdir(), "kervan-safegit-"));
  const dir = join(root, "repo");
  mkdirSync(dir);
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  git(dir, "config", "user.name", "T");
  git(dir, "config", "user.email", "t@t");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
  return { dir, marker: join(root, "ran") };
}

/** What an agent with write access to the folder could plant: a command for git to run. */
function plantHook(dir: string, name: string, marker: string): void {
  writeFileSync(join(dir, ".git", "hooks", name), `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
}

describe("planted commands in a session's repository", () => {
  it("really do run under plain git, so the tests below mean something", () => {
    const { dir, marker } = repository();
    plantHook(dir, "post-commit", marker);
    writeFileSync(join(dir, "a.txt"), "two\n");
    git(dir, "commit", "-qam", "plain");
    assert.ok(existsSync(marker), "plain git ran the hook");
  });

  it("don't run on a commit from the app: hooks", async () => {
    const { dir, marker } = repository();
    for (const name of ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"]) plantHook(dir, name, marker);
    writeFileSync(join(dir, "a.txt"), "two\n");
    assert.match(await commitAll(dir, "from the app"), /from the app/);
    assert.ok(!existsSync(marker), "a hook ran");
  });

  it("don't run on a commit from the app: fsmonitor", async () => {
    const { dir, marker } = repository();
    const script = join(dir, "..", "monitor.sh");
    writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
    git(dir, "config", "core.fsmonitor", script);
    git(dir, "status"); // reads it as git normally would
    assert.ok(existsSync(marker), "plain git ran the fsmonitor");
    rmSync(marker);
    writeFileSync(join(dir, "a.txt"), "two\n");
    await commitAll(dir, "from the app");
    assert.ok(!existsSync(marker), "the fsmonitor ran");
  });

  it("don't run when a worktree is made", async () => {
    const { dir, marker } = repository();
    plantHook(dir, "post-checkout", marker);
    await addWorktree(dir, join(dir, "..", "tree"), "kervan/tree");
    assert.ok(existsSync(join(dir, "..", "tree", "a.txt")));
    assert.ok(!existsSync(marker), "post-checkout ran");
  });

  it("don't run when a pull request is pushed", async () => {
    const { dir, marker } = repository();
    const origin = join(dir, "..", "origin.git");
    execFileSync("git", ["init", "-q", "--bare", origin]);
    git(dir, "remote", "add", "origin", origin);
    git(dir, "push", "-q", "origin", "main");
    git(dir, "fetch", "-q", "origin");
    for (const name of ["pre-push", "post-commit", "post-checkout", "reference-transaction"]) plantHook(dir, name, marker);
    writeFileSync(join(dir, "a.txt"), "two\n");
    rmSync(marker, { force: true });
    const result = await openPullRequest(dir, { title: "Change", body: "b", sessionId: "abcd1234" });
    assert.match(result.branch, /^kervan\//);
    assert.ok(git(origin, "branch", "--list", result.branch).includes(result.branch), "it was pushed");
    assert.ok(!existsSync(marker), "a hook ran");
  });

  it("a commit still works in a repository using its own hooks folder, as husky sets up", async () => {
    const { dir, marker } = repository();
    mkdirSync(join(dir, ".husky"));
    writeFileSync(join(dir, ".husky", "post-commit"), `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
    git(dir, "config", "core.hooksPath", ".husky");
    writeFileSync(join(dir, "a.txt"), "two\n");
    await commitAll(dir, "with husky");
    assert.ok(!existsSync(marker));
  });
});

describe("settings Kervan won't run git under", () => {
  it("refuses a filter that would run a command, and runs nothing", async () => {
    const { dir, marker } = repository();
    git(dir, "config", "filter.x.clean", `touch ${marker}; cat`);
    writeFileSync(join(dir, ".gitattributes"), "*.txt filter=x\n");
    writeFileSync(join(dir, "a.txt"), "two\n");
    await assert.rejects(commitAll(dir, "no"), /filter\.x\.clean/);
    assert.ok(!existsSync(marker), "the filter ran");
    await assert.rejects(addWorktree(dir, join(dir, "..", "tree"), "kervan/x"), /filter\.x\.clean/);
  });

  for (const [key, value] of [
    ["diff.external", "/tmp/evil"],
    ["diff.x.textconv", "/tmp/evil"],
    ["merge.x.driver", "/tmp/evil"],
    ["core.sshCommand", "/tmp/evil"],
    ["credential.helper", "!/tmp/evil"],
    ["url.https://evil.example/.insteadOf", "https://github.com/"],
    ["http.proxy", "http://evil.example"],
    ["protocol.ext.allow", "always"],
    ["remote.origin.pushurl", "https://evil.example/x.git"],
    ["core.worktree", "/etc"],
  ]) {
    it(`refuses ${key}`, async () => {
      const { dir } = repository();
      git(dir, "config", key, value);
      await assert.rejects(assertSafeRepository(dir), /can run a command or redirect git/);
    });
  }

  it("follows include.path, so settings can't be hidden in another file", async () => {
    const { dir } = repository();
    const other = join(dir, "..", "more.config");
    writeFileSync(other, "[filter \"y\"]\n\tclean = /tmp/evil\n");
    git(dir, "config", "include.path", other);
    await assert.rejects(assertSafeRepository(dir), /filter\.y\.clean/);
  });

  it("leaves ordinary settings and Git LFS alone", async () => {
    const { dir } = repository();
    git(dir, "config", "core.hooksPath", ".husky");
    git(dir, "config", "branch.main.remote", "origin");
    git(dir, "config", "my-tool.anything", "value");
    git(dir, "config", "filter.lfs.clean", "git-lfs clean -- %f");
    git(dir, "config", "filter.lfs.smudge", "git-lfs smudge -- %f");
    git(dir, "config", "filter.lfs.process", "git-lfs filter-process");
    git(dir, "config", "filter.lfs.required", "true");
    await assertSafeRepository(dir);
  });

  it("doesn't take a filter that only looks like Git LFS's", () => {
    assert.equal(refusedSetting("local\0filter.lfs.clean\ngit-lfs clean -- %f; touch /tmp/x\0"), "filter.lfs.clean");
  });

  it("trusts the server's own config, and reads a setting with no value", () => {
    assert.equal(refusedSetting("global\0filter.lfs.clean\nanything\0system\0http.proxy\nhttp://proxy\0"), undefined);
    assert.equal(refusedSetting("local\0core.bare\nfalse\0local\0http.proxy\0"), "http.proxy");
  });
});
