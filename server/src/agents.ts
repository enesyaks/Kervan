import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** How to start an agent that speaks ACP over stdio. */
export interface AgentCommand {
  command: string;
  args: string[];
  env?: Record<string, string>;
}

export type AgentRegistry = ReadonlyMap<string, AgentCommand>;

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

// M7 moves this into agents.yaml. Until then: Claude Code through its ACP adapter.
export function defaultAgents(): AgentRegistry {
  return new Map([["claude", { command: join(serverRoot, "node_modules/.bin/claude-agent-acp"), args: [] }]]);
}
