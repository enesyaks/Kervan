import { spawn } from "node:child_process";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";
import { sendJson } from "./files.ts";
import { log } from "./log.ts";
import { KervanError } from "./protocol.ts";
import type { NodeHub } from "./nodes.ts";

/** server/ — what a node runs, the same code as the hub. */
const SERVER_ROOT = join(import.meta.dirname, "..");
const MAX_JOIN_BODY = 4096;

/**
 * Adding a node without editing files: the app asks the hub for an invite and shows one command,
 *   curl -fsSL 'http://<hub>/v1/node/install?code=…' | sudo bash
 * The script it fetches installs Node.js, this code (from /v1/node/bundle.tar.gz), trades the invite
 * for the node's own token (/v1/node/join) and starts the kervan-node service. These three routes take
 * no bearer token: the single-use, short-lived invite code is the credential.
 */
export async function handleOnboarding(req: IncomingMessage, res: ServerResponse, nodes: NodeHub): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (!url.pathname.startsWith("/v1/node/")) return false;
  try {
    if (req.method === "GET" && url.pathname === "/v1/node/install") {
      const code = url.searchParams.get("code") ?? "";
      const name = nodes.invited(code);
      // The address the node used to reach us is the one it should keep using.
      const host = req.headers.host ?? "kervan:7420";
      res.writeHead(200, { "content-type": "text/x-shellscript; charset=utf-8" });
      res.end(installScript({ hubHttp: `http://${host}`, hubWs: nodes.hubUrls(host).join(","), code, name }));
    } else if (req.method === "GET" && url.pathname === "/v1/node/bundle.tar.gz") {
      nodes.invited(url.searchParams.get("code") ?? "");
      res.writeHead(200, { "content-type": "application/gzip" });
      const tar = spawn("tar", ["-czf", "-", "--exclude=./node_modules", "--exclude=./data", "--exclude=./test", "-C", SERVER_ROOT, "."], {
        env: { ...process.env, COPYFILE_DISABLE: "1" }, // no macOS ._ files in the archive
      });
      tar.stdout.pipe(res);
      tar.on("error", (error) => res.destroy(error));
    } else if (req.method === "POST" && url.pathname === "/v1/node/join") {
      const { code } = JSON.parse(await readBody(req)) as { code?: unknown };
      if (typeof code !== "string") throw new KervanError("bad_message", "join needs the invite code");
      sendJson(res, 200, nodes.join(code));
    } else {
      sendJson(res, 404, { error: "not_found" });
    }
  } catch (error) {
    if (res.headersSent) {
      res.destroy();
    } else if (error instanceof KervanError || error instanceof SyntaxError) {
      log("warn", "node onboarding refused", { path: url.pathname, error: error.message });
      sendJson(res, 403, { error: "invite_invalid", message: error.message });
    } else {
      log("error", "node onboarding failed", { path: url.pathname, error: String(error) });
      sendJson(res, 500, { error: "internal" });
    }
  }
  return true;
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk: Buffer) => {
      body += chunk.toString("utf8");
      if (body.length > MAX_JOIN_BODY) req.destroy(new Error("too large"));
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

const shell = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;

/** The systemd unit a node runs under; the hub's own unit is infra/kervan.service. */
export const NODE_UNIT = `[Unit]
Description=Kervan node (runs agents for a Kervan hub)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=kervan
Group=kervan
WorkingDirectory=/opt/kervan/server
EnvironmentFile=/etc/kervan/node.env
Environment=KERVAN_WORKSPACES_DIR=/srv/kervan/workspaces
ExecStart=/usr/bin/node src/node-main.ts
Restart=always
RestartSec=2
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/srv/kervan /home/kervan

[Install]
WantedBy=multi-user.target
`;

/** The node's setup, for Debian/Ubuntu. Safe to run again: it updates the code and keeps going. */
/** `hubWs`: the hub's ws:// addresses, comma separated, the one the script came from first. */
export function installScript({ hubHttp, hubWs, code, name }: { hubHttp: string; hubWs: string; code: string; name: string }): string {
  return `#!/usr/bin/env bash
# Kervan node setup, served by the hub at ${hubHttp}.
# Run on the new machine: curl -fsSL '${hubHttp}/v1/node/install?code=…' | sudo bash
set -euo pipefail
HUB_HTTP=${shell(hubHttp)}
HUB_WS=${shell(hubWs)}
CODE=${shell(code)}
NAME=${shell(name)}
NODE_MAJOR=24

if [[ $EUID -ne 0 ]]; then echo "Kervan: run this command with sudo." >&2; exit 1; fi
if ! command -v apt-get >/dev/null; then echo "Kervan: setup supports only Debian and Ubuntu (apt) for now." >&2; exit 1; fi

echo "==> Kervan: checking the hub ($HUB_HTTP)"
if ! curl -fsS --max-time 10 "$HUB_HTTP/health" >/dev/null; then
  echo "Kervan: this machine can't reach the hub. Join the same Tailscale network first (sudo tailscale up)." >&2
  exit 1
fi

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# libnss-mdns + avahi: lets the node find the hub as <host>.local even after the hub's IP changes.
apt-get install -y -qq ca-certificates curl gnupg python3 tar avahi-daemon libnss-mdns >/dev/null

echo "==> Node.js $NODE_MAJOR"
if ! command -v node >/dev/null || [[ "$(node -v)" != v$NODE_MAJOR.* ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

echo "==> user and folders"
id kervan >/dev/null 2>&1 || useradd --create-home --shell /bin/bash kervan
install -d -o kervan -g kervan -m 750 /srv/kervan /srv/kervan/workspaces
install -d -m 755 /opt/kervan /etc/kervan
# Whoever ran sudo can later update the code with infra/deploy.sh and restart only this service.
OWNER="\${SUDO_USER:-root}"
install -d -o "$OWNER" -g kervan -m 755 /opt/kervan/server
if [[ "$OWNER" != root ]]; then
  echo "$OWNER ALL=(root) NOPASSWD: /usr/bin/systemctl restart kervan-node, /usr/bin/systemctl status kervan-node" > /etc/sudoers.d/kervan-node
  chmod 440 /etc/sudoers.d/kervan-node
  visudo -cf /etc/sudoers.d/kervan-node >/dev/null
fi

echo "==> Kervan code"
curl -fsSL "$HUB_HTTP/v1/node/bundle.tar.gz?code=$CODE" | tar -xz -C /opt/kervan/server
chown -R "$OWNER":kervan /opt/kervan/server
(cd /opt/kervan/server && sudo -u "$OWNER" npm ci --omit=dev --no-audit --no-fund --loglevel=error)

echo "==> joining the hub as '$NAME'"
TOKEN="$(curl -fsSL -X POST -H 'content-type: application/json' -d "{\\"code\\":\\"$CODE\\"}" "$HUB_HTTP/v1/node/join" \\
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')"
umask 077
printf 'KERVAN_HUB_URL=%s\\nKERVAN_NODE_TOKEN=%s\\nKERVAN_NODE_NAME=%s\\n' "$HUB_WS" "$TOKEN" "$NAME" > /etc/kervan/node.env
chown root:kervan /etc/kervan/node.env
chmod 640 /etc/kervan/node.env

echo "==> service"
cat > /etc/systemd/system/kervan-node.service <<'UNIT'
${NODE_UNIT}UNIT
systemctl daemon-reload
systemctl enable kervan-node >/dev/null
systemctl restart kervan-node

cat <<DONE

Kervan: '$NAME' is installed and connecting to the hub; the app will show it as connected.
Agents need to sign in on this machine too: add API keys to /etc/kervan/node.env
(ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY) and run 'sudo systemctl restart kervan-node',
or sign the agent in yourself as the kervan user (sudo -iu kervan).
DONE
`;
}
