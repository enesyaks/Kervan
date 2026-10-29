type Level = "debug" | "info" | "warn" | "error";

// One JSON object per line on stdout; journald captures it on the VM.
export function log(level: Level, msg: string, fields: Record<string, unknown> = {}): void {
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }) + "\n");
}
