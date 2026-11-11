#!/usr/bin/env bash
# Sets up a Kervan hub on a fresh Debian/Ubuntu machine without questions. The Mac app copies this
# folder to /tmp/kervan-setup over SSH (with server.tar.gz, kervan.service and the access token it
# generated) and runs:  sudo env ACCESS=tailscale bash /tmp/kervan-setup/hub-setup.sh
# Safe to run again: it updates the code and keeps going. Prints "==> step" lines the app follows.
# Kervan answers only over Tailscale, which encrypts the traffic. SSH stays open on the home network, for setup itself.
# ACCESS=update replaces the code and the service, keeps the settings, and closes the home network if Tailscale is up
# here; if it isn't, that stays open, so an update never locks anyone out.
# ACCESS=podman only installs rootless Podman for builds in containers, and restarts the service.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACCESS="${ACCESS:-tailscale}"    # tailscale; update; podman
PORT=7420
NODE_MAJOR=24
OWNER="${SUDO_USER:-root}"

if [[ $EUID -ne 0 ]]; then echo "Kervan: run this script with sudo." >&2; exit 1; fi
if ! command -v apt-get >/dev/null; then echo "Kervan: setup supports only Debian and Ubuntu (apt) for now." >&2; exit 1; fi
if [[ ! -s "$HERE/server.tar.gz" || ! -s "$HERE/token" ]]; then echo "Kervan: setup files are missing; start again from the app." >&2; exit 1; fi
# The token must not stay in /tmp, whether the setup works or not.
TOKEN="$(tr -d '[:space:]' < "$HERE/token")"
trap 'rm -f "$HERE/token"' EXIT

# ACCESS=podman sets up builds in throwaway containers (container_run) and nothing else: rootless Podman as the
# server's own user, so a container sees the folder it is given and none of this machine's keys. The app asks
# for it with its Install button; an ordinary update leaves Podman as it finds it.
if [[ "$ACCESS" == podman ]]; then
  echo "==> packages (podman)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq podman uidmap >/dev/null
  id kervan >/dev/null 2>&1 || { echo "Kervan: there's no kervan user here; set the server up first." >&2; exit 1; }
  # Rootless containers need a range of ids of their own; useradd usually gave the user one already.
  grep -q '^kervan:' /etc/subuid || usermod --add-subuids 524288-589823 kervan
  grep -q '^kervan:' /etc/subgid || usermod --add-subgids 524288-589823 kervan
  # Keeps /run/user/<uid> there without a login, which is where Podman keeps its runtime state.
  loginctl enable-linger kervan

  echo "==> service"
  # The unit that lets the service write Podman's runtime folder; an older one keeps it read-only.
  install -m 644 "$HERE/kervan.service" /etc/systemd/system/kervan.service
  systemctl daemon-reload
  systemctl restart kervan
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"containers":true' && break
    sleep 1
  done
  curl -fsS "http://127.0.0.1:$PORT/health" | grep -q '"containers":true' \
    || { echo "Kervan: podman is installed but the server doesn't see it; see journalctl -u kervan." >&2; exit 1; }
  echo "==> ready"
  echo "Kervan: builds in containers are on (podman)."
  exit 0
fi

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# gh lets the server open pull requests from a session; connect it from the app: Settings › General › GitHub.
apt-get install -y -qq ca-certificates curl gnupg git gh sqlite3 ufw python3 tar avahi-daemon >/dev/null

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
# Installing the agent adapters needs about a gigabyte. Out of space, npm warns its way to a tree without
# node_modules/.bin, where the server still starts but no agent can; say so here instead of leaving that behind.
FREE_MB="$(df -Pm /opt/kervan/server | awk 'NR == 2 { print $4 }')"
if [[ "${FREE_MB:-0}" -lt 1500 ]]; then
  echo "Kervan: ${FREE_MB:-0} MB free on the server; installing the agents needs about 1500. Make room, then start again from the app." >&2
  exit 1
fi
(cd /opt/kervan/server && sudo -u "$OWNER" npm ci --omit=dev --no-audit --no-fund --loglevel=error)
# What the server starts agents with: if the install stopped short of these, nothing would run an agent.
for adapter in claude-agent-acp codex-acp gemini; do
  [[ -x "/opt/kervan/server/node_modules/.bin/$adapter" ]] && continue
  echo "Kervan: the install left no $adapter, so no agent would start. Start again from the app." >&2
  exit 1
done

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

echo "==> Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null

echo "==> firewall"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow in on tailscale0 >/dev/null
ufw --force enable >/dev/null
fi

# Closes the home network: the rule older setups made, and the setting the server checks for itself.
close_home_network() {
  local dev cidr net
  ufw allow in on tailscale0 >/dev/null
  dev="$(ip route show default | awk '{print $5; exit}')"
  cidr="$(ip -4 -o addr show dev "$dev" | awk '{print $4; exit}')"
  if [[ -n "$cidr" ]]; then
    net="$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr")"
    ufw delete allow from "$net" to any port "$PORT" proto tcp >/dev/null 2>&1 || true
  fi
  grep -qxF KERVAN_TAILNET_ONLY=1 /etc/kervan/env || echo KERVAN_TAILNET_ONLY=1 >> /etc/kervan/env
}
if [[ "$ACCESS" != update ]] || { command -v tailscale >/dev/null && [[ -n "$(tailscale ip -4 2>/dev/null)" ]]; }; then
  close_home_network
  echo "Kervan: answers only over Tailscale now."
else
  echo "Kervan: Tailscale isn't set up here, so the home network stays open. Set it up in Settings > Web access."
fi

# Agents run as their own user, so what they run can't read the keys in /etc/kervan and /var/lib/kervan. Done on every run:
# hubs set up before this move here through Server update. Safe to run again. See docs/plans/agent-isolation.md.
echo "Kervan: separating agents from the server."
AGENT=kervan-agent
WORK=kervan-work
systemctl stop kervan 2>/dev/null || true
id "$AGENT" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$AGENT"
groupadd -f "$WORK"
usermod -aG "$WORK" kervan
usermod -aG "$WORK" "$AGENT"
chmod 750 /home/kervan "/home/$AGENT"
apt-get install -y -qq util-linux sudo >/dev/null


# Their sign-ins move with them; gh's stays with the server, which is what pushes.
for item in .claude .claude.json .codex .gemini; do
  if [[ -e "/home/kervan/$item" && ! -e "/home/$AGENT/$item" ]]; then
    mv "/home/kervan/$item" "/home/$AGENT/$item"
    chown -R "$AGENT:$AGENT" "/home/$AGENT/$item"
  fi
done
for key in user.name user.email; do
  value="$(sudo -u kervan git config --global "$key" 2>/dev/null || true)"
  [[ -z "$value" ]] || sudo -u "$AGENT" git config --global "$key" "$value"
done
# The server makes some folders here itself (project clones), so they aren't all the agent user's.
sudo -u "$AGENT" git config --global --replace-all safe.directory '*'

install -d -m 2775 -o "$AGENT" -g "$WORK" /srv/kervan
for folder in workspaces checkpoints tools run; do install -d -m 2770 -o "$AGENT" -g "$WORK" "/srv/kervan/$folder"; done
for folder in checkpoints tools; do
  if [[ -d "/var/lib/kervan/$folder" ]]; then
    cp -a "/var/lib/kervan/$folder/." "/srv/kervan/$folder/"
    rm -rf "/var/lib/kervan/$folder"
  fi
done
if [[ -f /var/lib/kervan/agents.json ]]; then sed -i 's#/var/lib/kervan/tools/#/srv/kervan/tools/#g' /var/lib/kervan/agents.json; fi
chown -R "$AGENT:$WORK" /srv/kervan
chmod -R g+rwX /srv/kervan
find /srv/kervan -type d -exec chmod g+s {} +

chmod 755 /opt/kervan/server/bin/run-agent
cat > /etc/sudoers.d/kervan-agent <<SUDOERS
Defaults!/opt/kervan/server/bin/run-agent !use_pty, !lecture
kervan ALL=($AGENT) NOPASSWD: /opt/kervan/server/bin/run-agent
SUDOERS
chmod 440 /etc/sudoers.d/kervan-agent
visudo -cf /etc/sudoers.d/kervan-agent >/dev/null

# Last, so a setup stopped earlier leaves the server starting agents as before.
for line in "KERVAN_AGENT_USER=$AGENT" KERVAN_CHECKPOINTS_DIR=/srv/kervan/checkpoints KERVAN_TOOLS_DIR=/srv/kervan/tools KERVAN_RUN_DIR=/srv/kervan/run; do
  grep -qxF "$line" /etc/kervan/env || echo "$line" >> /etc/kervan/env
done

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

if [[ "$ACCESS" != update ]] && ! tailscale status >/dev/null 2>&1; then
  echo "==> Tailscale sign-in"
  echo "Kervan: sign in with your Tailscale account at the link below."
  tailscale up
fi

echo "==> ready"
echo "Kervan: the hub is installed and running (port $PORT)."
