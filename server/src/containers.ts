import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { delimiter, join } from "node:path";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";

/** What an agent gets back from one command: enough of the end of the output to see why a build failed. */
export const MAX_OUTPUT = 20_000;
export const DEFAULT_TIMEOUT_SEC = 600;
export const MAX_TIMEOUT_SEC = 3600;
/** Images nobody has run for a week go, so a server that builds now and then doesn't fill its disk. */
const PRUNE_EVERY_MS = 24 * 60 * 60 * 1000;
const PRUNE_UNUSED_FOR = "168h";

/**
 * An image reference as a registry would take it. It must start with a letter or digit: an "image" of
 * `--privileged` or `-v /:/host` would otherwise reach the engine as an option, which is the one way an
 * agent could make a container see more than its own folder.
 */
const IMAGE = /^[A-Za-z0-9][A-Za-z0-9._\-/:@+]{0,255}$/;

export interface ContainerResult {
  exitCode: number;
  output: string;
  timedOut: boolean;
}

export function validImage(image: string): boolean {
  return IMAGE.test(image);
}

/**
 * The image a devcontainer.json names, if the project has one. The file allows comments, which JSON
 * doesn't, so line comments are dropped first; anything that still won't parse is ignored rather than
 * guessed at.
 */
export function devcontainerImage(folder: string): string | undefined {
  for (const file of [join(folder, ".devcontainer", "devcontainer.json"), join(folder, ".devcontainer.json")]) {
    if (!existsSync(file)) continue;
    try {
      const text = readFileSync(file, "utf8").replace(/^\s*\/\/.*$/gm, "");
      const image = (JSON.parse(text) as { image?: unknown }).image;
      if (typeof image === "string" && validImage(image)) return image;
    } catch {
      // Not plain enough to read; the project can still name an image itself.
    }
  }
  return undefined;
}

/** Podman unless told otherwise, then Docker: whichever is on PATH. */
export function findEngine(env: NodeJS.ProcessEnv = process.env): string | undefined {
  const chosen = env.KERVAN_CONTAINER_ENGINE?.trim();
  if (chosen === "off") return undefined;
  const names = chosen ? [chosen] : ["podman", "docker"];
  const dirs = (env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const name of names) {
    if (name.includes("/")) return existsSync(name) ? name : undefined;
    const found = dirs.map((dir) => join(dir, name)).find((path) => existsSync(path));
    if (found) return found;
  }
  return undefined;
}

/**
 * Builds in throwaway containers. Each command gets a fresh one made from an image, with the session's
 * folder mounted at /work and nothing else of this machine, and it is removed when the command ends —
 * the build's output stays in the folder, the container doesn't.
 */
export class Containers {
  readonly engine: string | undefined;
  private pruneTimer?: ReturnType<typeof setInterval>;

  /** `engine` is a path from findEngine(), or undefined for none: there's no default, so "none" can be said. */
  constructor(engine: string | undefined) {
    this.engine = engine;
  }

  get available(): boolean {
    return this.engine !== undefined;
  }

  /**
   * What the engine is told. Pure, so the line between "the agent's command" and "what this machine
   * lets a container do" can be tested without an engine. `umask 002` keeps what the build writes
   * editable by the agent, which runs as another user in the same group. Not a login shell: that reads
   * /etc/profile, which resets PATH and loses the toolchain an image puts on it (golang's go, for one).
   */
  static args(name: string, image: string, folder: string, command: string): string[] {
    return ["run", "--rm", "--init", "--name", name, "--pull=missing", "-v", `${folder}:/work`, "-w", "/work", image, "sh", "-c", `umask 002; ${command}`];
  }

  async run(image: string, folder: string, command: string, timeoutSec = DEFAULT_TIMEOUT_SEC): Promise<ContainerResult> {
    const engine = this.engine;
    if (!engine) throw new KervanError("bad_message", "no container engine on this server (podman or docker)");
    if (!validImage(image)) throw new KervanError("bad_message", `'${image}' isn't an image name`);
    const seconds = Math.min(Math.max(Math.round(timeoutSec), 1), MAX_TIMEOUT_SEC);
    // A name of our own, so a command that runs too long can be stopped even if the engine's client is gone.
    const name = `kervan-${randomBytes(6).toString("hex")}`;
    return new Promise((resolve) => {
      let output = "";
      let settled = false;
      const finish = (result: ContainerResult) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(result);
      };
      const child = spawn(engine, Containers.args(name, image, folder, command), { stdio: ["ignore", "pipe", "pipe"] });
      const keep = (chunk: Buffer) => {
        output += chunk.toString("utf8");
        if (output.length > MAX_OUTPUT * 2) output = output.slice(-MAX_OUTPUT);
      };
      child.stdout.on("data", keep);
      child.stderr.on("data", keep);
      // Answers at the limit rather than when the last pipe closes: something the build started can hold those
      // open long after, and the agent should hear now that its command was stopped.
      const timer = setTimeout(() => {
        execFile(engine, ["rm", "-f", name], () => {});
        child.kill("SIGTERM");
        finish({ exitCode: -1, output: output.slice(-MAX_OUTPUT), timedOut: true });
      }, seconds * 1000);
      child.on("close", (code) => finish({ exitCode: code ?? -1, output: output.slice(-MAX_OUTPUT), timedOut: false }));
      child.on("error", (error) => finish({ exitCode: -1, output: `couldn't start ${engine}: ${error.message}`, timedOut: false }));
    });
  }

  /** Clears out images no container has used for a week, once a day. */
  startPruning(): void {
    const engine = this.engine;
    if (!engine || this.pruneTimer) return;
    const prune = () =>
      execFile(engine, ["image", "prune", "-a", "-f", "--filter", `until=${PRUNE_UNUSED_FOR}`], (error) => {
        if (error) log("warn", "pruning old build images failed", { error: error.message });
      });
    this.pruneTimer = setInterval(prune, PRUNE_EVERY_MS);
    this.pruneTimer.unref();
  }

  close(): void {
    clearInterval(this.pruneTimer);
  }
}
