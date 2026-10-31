#!/usr/bin/env bash
# One-time bootstrap of an Ubuntu 24.04 VM for kervan.
# Usage (on the VM, from the copied infra/ folder): sudo bash vm-setup.sh
set -euo pipefail

NODE_MAJOR=24
KERVAN_USER=kervan
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo bash $0" >&2
  exit 1
fi

echo "==> packages"
apt-get update
# avahi: nodes on the LAN find the hub as <hostname>.local, whatever IP it gets.
# gh lets the server open pull requests from a session. Sign in once as the service user:
#   sudo -u kervan -H gh auth login && sudo -u kervan -H gh auth setup-git
apt-get install -y ca-certificates curl gnupg git gh build-essential sqlite3 ufw rsync avahi-daemon

echo "==> node ${NODE_MAJOR}"
if ! command -v node >/dev/null || [[ "$(node -v)" != v${NODE_MAJOR}.* ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi

echo "==> tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> user and directories"
id "$KERVAN_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$KERVAN_USER"
install -d -o "$KERVAN_USER" -g "$KERVAN_USER" -m 750 /var/lib/kervan /srv/kervan /srv/kervan/workspaces
install -d -m 755 /opt/kervan /etc/kervan

# The admin who ran this script becomes the deploy user: owns the code dir and may
# restart the service without a password. Nothing else gets passwordless sudo.
DEPLOY_USER="${SUDO_USER:-root}"
install -d -o "$DEPLOY_USER" -g "$KERVAN_USER" -m 755 /opt/kervan/server
if [[ "$DEPLOY_USER" != root ]]; then
  echo "$DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart kervan, /usr/bin/systemctl status kervan" > /etc/sudoers.d/kervan-deploy
  chmod 440 /etc/sudoers.d/kervan-deploy
  visudo -cf /etc/sudoers.d/kervan-deploy
fi
if [[ ! -f /etc/kervan/env ]]; then
  cat > /etc/kervan/env <<'EOF'
# Bound on all interfaces; ufw only lets traffic in over tailscale0.
KERVAN_HOST=0.0.0.0
KERVAN_PORT=7420
KERVAN_DATA_DIR=/var/lib/kervan
EOF
fi
if ! grep -q '^KERVAN_TOKEN=' /etc/kervan/env; then
  echo "KERVAN_TOKEN=$(openssl rand -hex 32)" >> /etc/kervan/env
fi
chown root:"$KERVAN_USER" /etc/kervan/env
chmod 640 /etc/kervan/env

echo "==> firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH          # keep LAN ssh for deploys; tighten to tailscale0 later if you like
ufw allow in on tailscale0
ufw --force enable

echo "==> systemd unit"
install -m 644 "$SCRIPT_DIR/kervan.service" /etc/systemd/system/kervan.service
systemctl daemon-reload
systemctl enable kervan

cat <<EOF

Done. Next:
  1. sudo tailscale up            # log the VM into your tailnet
  2. From your Mac: infra/deploy.sh <user>@<vm-tailscale-name>
EOF
