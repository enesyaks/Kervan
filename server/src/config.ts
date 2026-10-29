import { join, resolve } from "node:path";

export interface KervanConfig {
  host: string;
  port: number;
  dataDir: string;
  /** Each session gets its own folder here; ACP needs absolute paths. */
  workspacesDir: string;
  token: string;
  maxUploadBytes: number;
  /** agents.yaml; without it the builtin adapters are offered. */
  agentsFile?: string;
}

const MIN_TOKEN_LENGTH = 16;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): KervanConfig {
  const port = Number(env.KERVAN_PORT ?? 7420);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`KERVAN_PORT is not a valid port: ${env.KERVAN_PORT}`);
  }
  const token = env.KERVAN_TOKEN ?? "";
  if (token.length < MIN_TOKEN_LENGTH) {
    throw new Error(`KERVAN_TOKEN must be set (at least ${MIN_TOKEN_LENGTH} characters)`);
  }
  const dataDir = env.KERVAN_DATA_DIR ?? "./data";
  return {
    host: env.KERVAN_HOST ?? "127.0.0.1",
    port,
    dataDir,
    workspacesDir: resolve(env.KERVAN_WORKSPACES_DIR ?? join(dataDir, "workspaces")),
    token,
    maxUploadBytes: Number(env.KERVAN_MAX_UPLOAD_MB ?? 512) * 1024 * 1024,
    ...(env.KERVAN_AGENTS_FILE ? { agentsFile: env.KERVAN_AGENTS_FILE } : {}),
  };
}
