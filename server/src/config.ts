export interface KervanConfig {
  host: string;
  port: number;
  dataDir: string;
  token: string;
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
  return {
    host: env.KERVAN_HOST ?? "127.0.0.1",
    port,
    dataDir: env.KERVAN_DATA_DIR ?? "./data",
    token,
  };
}
