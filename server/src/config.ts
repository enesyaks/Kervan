export interface KervanConfig {
  host: string;
  port: number;
  dataDir: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): KervanConfig {
  const port = Number(env.KERVAN_PORT ?? 7420);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`KERVAN_PORT is not a valid port: ${env.KERVAN_PORT}`);
  }
  return {
    host: env.KERVAN_HOST ?? "127.0.0.1",
    port,
    dataDir: env.KERVAN_DATA_DIR ?? "./data",
  };
}
