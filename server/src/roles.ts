import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { KervanError } from "./protocol.ts";

const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_INSTRUCTIONS = 20_000;

/** A job in a team: which agent does it, what it's told up front, what it may use. */
export interface Role {
  id: string;
  name: string;
  agent: string;
  /** Given to the agent before the first message, unseen by the user. */
  instructions: string;
  skills: string[];
  mcpServers: string[];
  /** A lead: in a team, this member may start and message helper agents. */
  lead?: boolean;
}

export interface RoleChecks {
  hasAgent: (id: string) => boolean;
  hasSkill: (name: string) => boolean;
  hasMcp: (name: string) => boolean;
}

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

const names = (value: unknown, what: string): string[] => {
  if (value === undefined) return [];
  if (!Array.isArray(value) || !value.every((v) => typeof v === "string")) return bad(`${what} must be a list of names`);
  return [...new Set(value as string[])];
};

/** Roles the user defined, in `roles.json`. Checked against the agents, skills and MCP servers that exist. */
export class RoleRegistry {
  private readonly file: string;
  private readonly checks: RoleChecks;
  private roles: Map<string, Role>;

  constructor(file: string, checks: RoleChecks) {
    this.file = file;
    this.checks = checks;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Role[]) : [];
    this.roles = new Map(stored.map((role) => [role.id, role]));
  }

  get(id: string): Role | undefined {
    return this.roles.get(id);
  }

  list(): Role[] {
    return [...this.roles.values()].sort((a, b) => a.name.localeCompare(b.name, "tr"));
  }

  save(input: unknown): Role {
    if (typeof input !== "object" || input === null || Array.isArray(input)) bad("role must be an object");
    const raw = input as Record<string, unknown>;
    const { id, name, agent } = raw;
    if (typeof id !== "string" || !NAME.test(id)) bad("role id must be lowercase letters, digits or '-'");
    if (typeof name !== "string" || name.trim() === "") bad("role needs a name");
    if (typeof agent !== "string" || !this.checks.hasAgent(agent)) bad(`no agent named '${String(agent)}'`);
    const instructions = raw.instructions ?? "";
    if (typeof instructions !== "string" || instructions.length > MAX_INSTRUCTIONS) {
      bad(`instructions must be text of at most ${MAX_INSTRUCTIONS} characters`);
    }
    const skills = names(raw.skills, "skills");
    const missingSkill = skills.find((s) => !this.checks.hasSkill(s));
    if (missingSkill) bad(`no skill named '${missingSkill}'`);
    const mcpServers = names(raw.mcpServers, "mcpServers");
    const missingMcp = mcpServers.find((s) => !this.checks.hasMcp(s));
    if (missingMcp) bad(`no MCP server named '${missingMcp}'`);

    const role: Role = {
      id: id as string,
      name: (name as string).trim(),
      agent: agent as string,
      instructions: (instructions as string).trim(),
      skills,
      mcpServers,
      ...(raw.lead === true ? { lead: true } : {}),
    };
    this.roles.set(role.id, role);
    this.persist();
    return role;
  }

  remove(id: string): void {
    if (!this.roles.delete(id)) bad(`no role named '${id}'`);
    this.persist();
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.list(), null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}
