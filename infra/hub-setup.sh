#!/usr/bin/env bash
# Sets up a Kervan hub on a fresh Debian/Ubuntu machine without questions. The Mac app copies this
# folder to /tmp/kervan-setup over SSH (with server.tar.gz, kervan.service and the access token it
# generated) and runs:  sudo env ACCESS=lan|tailscale|both bash /tmp/kervan-setup/hub-setup.sh
# Safe to run again: it updates the code and keeps going. Prints "==> step" lines the app follows.
# ACCESS=update only replaces the code and the service: settings, firewall and Tailscale stay as they are.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACCESS="${ACCESS:-lan}"          # lan: this network only; tailscale: Tailscale only; both; update
PORT=7420
NODE_MAJOR=24
OWNER="${SUDO_USER:-root}"

if [[ $EUID -ne 0 ]]; then echo "Kervan: run this script with sudo." >&2; exit 1; fi
if ! command -v apt-get >/dev/null; then echo "Kervan: setup supports only Debian and Ubuntu (apt) for now." >&2; exit 1; fi
if [[ ! -s "$HERE/server.tar.gz" || ! -s "$HERE/token" ]]; then echo "Kervan: setup files are missing; start again from the app." >&2; exit 1; fi
# The token must not stay in /tmp, whether the setup works or not.
TOKEN="$(tr -d '[:space:]' < "$HERE/token")"
trap 'rm -f "$HERE/token"' EXIT

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git sqlite3 ufw python3 tar avahi-daemon >/dev/null

echo "==> Node.js $NODE_MAJOR"
if ! command -v node >/dev/null || [[ "$(node -v)" != v$NODE_MAJOR.* ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

echo "==> user and folders"
id kervan >/dev/null 2>&1 || useradd --create-home --shell /bin/bash kervan
install -d -o kervan -g kervan -m 750 /var/lib/kervan /srv/kervan /srv/kervan/workspaces
install -d -m 755 /opt/kervan /etc/kervan
install -d -o "$OWNER" -g kervan -m 755 /opt/kervan/server
if [[ "$OWNER" != root ]]; then
  # The admin can later update the code with infra/deploy.sh and restart only this service.
  echo "$OWNER ALL=(root) NOPASSWD: /usr/bin/systemctl restart kervan, /usr/bin/systemctl status kervan" > /etc/sudoers.d/kervan-deploy
  chmod 440 /etc/sudoers.d/kervan-deploy
  visudo -cf /etc/sudoers.d/kervan-deploy >/dev/null
fi

echo "==> Kervan code"
tar -xzf "$HERE/server.tar.gz" -C /opt/kervan/server
chown -R "$OWNER":kervan /opt/kervan/server
(cd /opt/kervan/server && sudo -u "$OWNER" npm ci --omit=dev --no-audit --no-fund --loglevel=error)

if [[ "$ACCESS" != update ]]; then
echo "==> settings"
umask 077
{
  echo "KERVAN_HOST=0.0.0.0"
  echo "KERVAN_PORT=$PORT"
  echo "KERVAN_DATA_DIR=/var/lib/kervan"
  echo "KERVAN_WORKSPACES_DIR=/srv/kervan/workspaces"
  # The app generated this token and already keeps it in the Mac's Keychain.
  echo "KERVAN_TOKEN=$TOKEN"
  # Keep whatever else was added by hand (API keys), minus the lines set above.
  if [[ -f /etc/kervan/env ]]; then grep -vE '^KERVAN_(HOST|PORT|DATA_DIR|WORKSPACES_DIR|TOKEN)=' /etc/kervan/env || true; fi
} > /etc/kervan/env.new
mv /etc/kervan/env.new /etc/kervan/env
chown root:kervan /etc/kervan/env
chmod 640 /etc/kervan/env
umask 022

if [[ "$ACCESS" != lan ]]; then
  echo "==> Tailscale"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi

echo "==> firewall"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
if [[ "$ACCESS" != lan ]]; then ufw allow in on tailscale0 >/dev/null; fi
if [[ "$ACCESS" != tailscale ]]; then
  DEV="$(ip route show default | awk '{print $5; exit}')"
  CIDR="$(ip -4 -o addr show dev "$DEV" | awk '{print $4; exit}')"
  NET="$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$CIDR")"
  ufw allow from "$NET" to any port "$PORT" proto tcp >/dev/null
  echo "Kervan: devices on $NET can connect to port $PORT."
fi
ufw --force enable >/dev/null
fi

echo "==> service"
install -m 644 "$HERE/kervan.service" /etc/systemd/system/kervan.service
systemctl daemon-reload
systemctl enable kervan >/dev/null
systemctl restart kervan
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null || { echo "Kervan: the service didn't start; see journalctl -u kervan." >&2; exit 1; }

if [[ "$ACCESS" != lan && "$ACCESS" != update ]] && ! tailscale status >/dev/null 2>&1; then
  echo "==> Tailscale sign-in"
  echo "Kervan: sign in with your Tailscale account at the link below."
  tailscale up
fi

echo "==> ready"
echo "Kervan: the hub is installed and running (port $PORT)."
