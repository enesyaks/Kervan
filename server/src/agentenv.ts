/**
 * What an agent, or a command Kervan runs in its folder, gets to see of the server's environment: an allowed list,
 * so the app's key (KERVAN_TOKEN) and other agents' API keys stay out of reach, including ones added later.
 * See docs/plans/agent-isolation.md: this takes them out of the environment; the files need a separate user.
 */
const ALLOWED = new Set([
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LANGUAGE", "TZ", "TERM", "COLORTERM", "TMPDIR", "TMP", "TEMP",
  "SSH_AUTH_SOCK",
  // Reaching the network from where the server is: its proxy and its certificates.
  "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
  "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
]);
const ALLOWED_PREFIXES = ["LC_", "XDG_"];

/** Whether `name` is on a list of exact names and `PREFIX*` patterns. */
function listed(name: string, patterns: readonly string[]): boolean {
  return patterns.some((pattern) => (pattern.endsWith("*") ? name.startsWith(pattern.slice(0, -1)) : name === pattern));
}

/** The allowed part of `source`, plus the names in `inherit` (exact, or `PREFIX*`). */
export function cleanEnv(inherit: readonly string[] = [], source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [name, value] of Object.entries(source)) {
    if (value === undefined) continue;
    if (ALLOWED.has(name) || ALLOWED_PREFIXES.some((prefix) => name.startsWith(prefix)) || listed(name, inherit)) env[name] = value;
  }
  return env;
}

/** An agent's environment: the allowed part, what its definition inherits, and its own settings on top. */
export function agentEnv(command: { env?: Record<string, string>; inheritEnv?: string[] }, source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  return { ...cleanEnv(command.inheritEnv ?? [], source), ...command.env };
}
