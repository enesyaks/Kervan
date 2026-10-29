#!/usr/bin/env bash
# Push server/ to the VM and restart the service.
# Usage (on the Mac): infra/deploy.sh <user>@<vm-host> [kervan|kervan-node]
# <user> must be the admin who ran vm-setup.sh (owns /opt/kervan/server, may restart the service).
# A node machine gets the same code; pass kervan-node to restart that service instead of the hub.
set -euo pipefail

TARGET="${1:?usage: infra/deploy.sh <user>@<vm-host> [kervan|kervan-node]}"
SERVICE="${2:-kervan}"
[[ "$SERVICE" == kervan || "$SERVICE" == kervan-node ]] || { echo "service must be kervan or kervan-node" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rsync -az --delete --exclude node_modules --exclude data "$ROOT/server/" "$TARGET:/opt/kervan/server/"

ssh "$TARGET" "
  set -e
  cd /opt/kervan/server && npm ci --omit=dev --no-audit --no-fund --loglevel=error
  sudo -n /usr/bin/systemctl restart $SERVICE
  sleep 1
  if [ $SERVICE = kervan ]; then curl -fsS http://127.0.0.1:7420/health && echo; else sudo -n /usr/bin/systemctl status $SERVICE --no-pager | head -3; fi
"
