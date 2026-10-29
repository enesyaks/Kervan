#!/usr/bin/env bash
# Push server/ to the VM and restart the service.
# Usage (on the Mac): infra/deploy.sh <user>@<vm-host>
# <user> must be the admin who ran vm-setup.sh (owns /opt/kervan/server, may restart the service).
set -euo pipefail

TARGET="${1:?usage: infra/deploy.sh <user>@<vm-host>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rsync -az --delete --exclude node_modules --exclude data "$ROOT/server/" "$TARGET:/opt/kervan/server/"

ssh "$TARGET" '
  set -e
  sudo -n /usr/bin/systemctl restart kervan
  sleep 1
  curl -fsS http://127.0.0.1:7420/health && echo
'
