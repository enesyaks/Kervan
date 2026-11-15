import { lstat, readdir, readFile } from "node:fs/promises";
import { Readable } from "node:stream";
import { resolveInside, upload } from "./files.ts";
import { KervanError, type ProjectEnv, type ProjectInfo } from "./protocol.ts";
import { ENV_FILE, MAX_ENV_BYTES, forbiddenPath, isExampleEnv, parseEnv } from "./redlines.ts";

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

/** Checks a file name the app sent: an env file at the folder's top, nothing else. */
export function envFileName(name: unknown): string {
  if (typeof name !== "string" || !ENV_FILE.test(name)) return bad(`'${String(name)}' isn't an env file name, like .env or .env.local`);
  return name;
}

/** The env files at the top of `root` (plain files, not links), `.env` first. */
export async function envFiles(root: string): Promise<string[]> {
  const names = await readdir(root).catch(() => [] as string[]);
  const files: string[] = [];
  for (const name of names) {
    if (!ENV_FILE.test(name)) continue;
    const info = await lstat(`${root}/${name}`).catch(() => undefined);
    if (info?.isFile()) files.push(name);
  }
  return files.sort((a, b) => (a === ".env" ? -1 : b === ".env" ? 1 : a.localeCompare(b)));
}

/** The text of an env file at the top of `root`, or undefined when there's none. */
export async function readEnvFile(root: string, name: string): Promise<string | undefined> {
  const path = await resolveInside(root, envFileName(name));
  const info = await lstat(path).catch(() => undefined);
  if (!info) return undefined;
  if (!info.isFile()) bad(`${name} isn't a plain file`);
  if (info.size > MAX_ENV_BYTES) bad(`${name} is larger than ${MAX_ENV_BYTES / 1024} KB`);
  return readFile(path, "utf8");
}

/** Writes an env file at the top of `root`, all at once, so a running app never reads half of it. */
export async function writeEnvFile(root: string, name: string, text: string): Promise<void> {
  if (Buffer.byteLength(text) > MAX_ENV_BYTES) bad(`${name} would be larger than ${MAX_ENV_BYTES / 1024} KB`);
  await upload(Readable.from([Buffer.from(text)]), root, envFileName(name), MAX_ENV_BYTES);
}

/**
 * Gives a new worktree the env files of the folder it was cut from: git leaves them out (they're ignored), and the
 * app an agent runs there needs them. A file the worktree already has stays.
 */
export async function copyEnvFiles(from: string, to: string): Promise<string[]> {
  const have = new Set(await envFiles(to));
  const copied: string[] = [];
  for (const name of await envFiles(from)) {
    if (have.has(name)) continue;
    const text = await readEnvFile(from, name);
    if (text === undefined) continue;
    await writeEnvFile(to, name, text);
    copied.push(name);
  }
  return copied;
}

/** A project's env file as the app shows it, with what an example file or an agent says is still missing. */
export async function projectEnv(project: ProjectInfo, file?: string): Promise<ProjectEnv> {
  const files = await envFiles(project.path);
  const chosen = file !== undefined ? envFileName(file) : (files.find((f) => !isExampleEnv(f)) ?? ".env");
  const text = await readEnvFile(project.path, chosen);
  const entries = parseEnv(text ?? "");
  const have = new Set(entries.map((e) => e.key));
  let missing: string[] = [];
  let example: string | undefined;
  if (!isExampleEnv(chosen)) {
    example = files.find(isExampleEnv);
    const wanted = example ? parseEnv((await readEnvFile(project.path, example)) ?? "").map((e) => e.key) : [];
    const asked = (project.envRequests ?? []).flatMap((r) => r.keys);
    missing = [...new Set([...wanted, ...asked])].filter((key) => !have.has(key));
  }
  const protectedBy = forbiddenPath(project.redLines, chosen);
  return {
    projectId: project.id,
    files,
    file: chosen,
    exists: text !== undefined,
    entries,
    missing,
    ...(example ? { example } : {}),
    ...(protectedBy ? { protectedBy } : {}),
  };
}
