import { arch, platform, release } from "node:os";
import { recentLogs } from "./log.ts";
import type { Diagnostics } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";
import { VERSION } from "./version.ts";

const startedAt = Date.now();

const PATTERNS: [RegExp, string][] = [
  [/sk-ant-[A-Za-z0-9_-]{8,}/g, "sk-ant-…"],
  [/sk-[A-Za-z0-9_-]{16,}/g, "sk-…"],
  [/AIza[0-9A-Za-z_-]{20,}/g, "AIza…"],
  [/gh[pousr]_[A-Za-z0-9]{20,}/g, "gh…"],
  [/bearer\s+\S+/gi, "Bearer …"],
  [/\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD))\s*[=:]\s*\S+/gi, "$1=…"],
  // Kervan's own tokens and invite codes: long runs of hex.
  [/\b[0-9a-f]{32,}\b/g, "…"],
];

/** Takes API keys, tokens and bearer headers out of text that leaves the server. Mirrors Redact in the Mac app. */
export function redact(text: string): string {
  return PATTERNS.reduce((result, [pattern, replacement]) => result.replace(pattern, replacement), text);
}

/** What a bug report needs from the server: versions, what runs and how, and recent log lines without secrets. */
export function diagnostics(sessions: SessionManager): Diagnostics {
  const byStatus: Record<string, number> = {};
  for (const session of sessions.list()) byStatus[session.status] = (byStatus[session.status] ?? 0) + 1;
  return {
    version: VERSION,
    node: process.version,
    os: `${platform()} ${release()} ${arch()}`,
    uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
    agents: (sessions.catalog?.list() ?? []).map(({ id, available, signedIn, node }) => ({
      id,
      available,
      ...(signedIn !== undefined ? { signedIn } : {}),
      node,
    })),
    nodes: (sessions.nodes?.list() ?? []).map(({ name, connected, version }) => ({ name, connected, ...(version ? { version } : {}) })),
    sessions: byStatus,
    logs: recentLogs().map(redact),
  };
}
