type Level = "debug" | "info" | "warn" | "error";

/** The last lines at info level and above, for "Report a problem"; debug lines may carry agent output. */
const RECENT_LINES = 300;
const recent: string[] = [];

// One JSON object per line on stdout; journald captures it on the VM.
export function log(level: Level, msg: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields });
  process.stdout.write(line + "\n");
  if (level === "debug") return;
  recent.push(line.length > 500 ? `${line.slice(0, 499)}…` : line);
  if (recent.length > RECENT_LINES) recent.shift();
}

/** What `log` kept, oldest first. Not redacted: callers that share it must redact. */
export function recentLogs(): string[] {
  return [...recent];
}
