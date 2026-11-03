#!/usr/bin/env bash
# Makes this Mac a Kervan node, so sessions started anywhere can use its agents and its Ollama (docs/plans/mac-node.md).
# Agents run as a separate hidden user, away from the logged-in user's files. Run with sudo:
#   sudo bash mac-node-setup.sh install --hub http://<hub>:7420 --code <invite> --name <node>
#   sudo bash mac-node-setup.sh verify
#   sudo bash mac-node-setup.sh keep-awake on|off
#   sudo bash mac-node-setup.sh remove
# Safe to run install again with a new invite: it updates the code and keeps the node's sign-ins and folders.
set -euo pipefail

NODE_USER=_kervan-node
ROOT=/opt/kervan-node
LABEL=com.enes.kervan.node
PLIST="/Library/LaunchDaemons/$LABEL.plist"
AWAKE_LABEL="$LABEL.awake"
AWAKE_PLIST="/Library/LaunchDaemons/$AWAKE_LABEL.plist"
NODE_MAJOR=24

fail() { echo "Kervan: $*" >&2; exit 1; }
usage() { sed -n '4,7p' "$0" | sed 's/^# *//' >&2; exit 64; }
step() { echo "==> $*"; }

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
case "$COMMAND" in install|verify|remove|keep-awake) ;; *) usage ;; esac

AWAKE=""
if [[ "$COMMAND" == keep-awake ]]; then
  AWAKE="${1:-}"
  [[ "$AWAKE" == on || "$AWAKE" == off ]] || usage
  shift
fi

HUB="" CODE="" NAME=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --hub) HUB="$2" ;;
    --code) CODE="$2" ;;
    --name) NAME="$2" ;;
    *) usage ;;
  esac
  shift 2
done

[[ "$(uname)" == Darwin ]] || fail "this script is for macOS. Other machines use the command from Settings > Nodes."
[[ $EUID -eq 0 ]] || fail "run this with sudo."

stop_daemon() { launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true; }

# A free id below 500, where macOS keeps service users: they get no login, and no place in the staff group.
free_id() {
  local id
  for id in $(seq 400 499); do
    if [[ -z "$(dscl . -search /Users UniqueID "$id" 2>/dev/null)" && -z "$(dscl . -search /Groups PrimaryGroupID "$id" 2>/dev/null)" ]]; then
      echo "$id"
      return
    fi
  done
  fail "no free id for the node's user."
}

make_user() {
  local id
  if dscl . -read "/Users/$NODE_USER" >/dev/null 2>&1; then
    # A removal that stopped halfway can leave the user without its group.
    if ! dscl . -read "/Groups/$NODE_USER" >/dev/null 2>&1; then
      id="$(dscl . -read "/Users/$NODE_USER" PrimaryGroupID | awk '{print $2}')"
      dscl . -create "/Groups/$NODE_USER"
      dscl . -create "/Groups/$NODE_USER" PrimaryGroupID "$id"
      dscl . -create "/Groups/$NODE_USER" Password '*'
    fi
    return
  fi
  id="$(free_id)"
  dscl . -create "/Groups/$NODE_USER"
  dscl . -create "/Groups/$NODE_USER" PrimaryGroupID "$id"
  dscl . -create "/Groups/$NODE_USER" Password '*'
  dscl . -create "/Users/$NODE_USER"
  dscl . -create "/Users/$NODE_USER" UniqueID "$id"
  dscl . -create "/Users/$NODE_USER" PrimaryGroupID "$id"
  dscl . -create "/Users/$NODE_USER" UserShell /usr/bin/false
  dscl . -create "/Users/$NODE_USER" RealName "Kervan Node"
  dscl . -create "/Users/$NODE_USER" NFSHomeDirectory "$ROOT/home"
  dscl . -create "/Users/$NODE_USER" Password '*'
  dscl . -create "/Users/$NODE_USER" IsHidden 1
}

# The first Node.js new enough; a daemon has no Homebrew on its PATH, so the places are named.
find_node() {
  local candidate major
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
    [[ -x "$candidate" ]] || continue
    major="$("$candidate" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [[ "$major" -ge "$NODE_MAJOR" ]]; then
      echo "$candidate"
      return
    fi
  done
  fail "Node.js $NODE_MAJOR or newer wasn't found. Install it with: brew install node"
}

install_node() {
  [[ -n "$HUB" && -n "$CODE" && -n "$NAME" ]] || usage
  [[ "$HUB" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || fail "--hub must look like http://kervan.example.ts.net:7420"
  [[ "$CODE" =~ ^[A-Za-z0-9_-]+$ ]] || fail "--code doesn't look like an invite code."
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || fail "--name must be lowercase letters, digits or '-'."

  local node_bin node_dir path_value bundle
  node_bin="$(find_node)"
  node_dir="$(dirname "$node_bin")"
  # Ollama and the agents' tools live next to Node.js on a Homebrew Mac.
  path_value="$node_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  # Terminal agents need it; without the Command Line Tools /usr/bin/python3 only offers to install them.
  PATH="$path_value" python3 -c 'pass' >/dev/null 2>&1 || echo "Kervan: python3 didn't run, so terminal agents won't work. Other agents will." >&2

  step "checking the hub ($HUB)"
  curl -fsS --max-time 10 "$HUB/health" >/dev/null || fail "this Mac can't reach the hub at $HUB."

  step "user and folders"
  stop_daemon
  make_user
  install -d -o root -g wheel -m 755 "$ROOT"
  install -d -o "$NODE_USER" -g "$NODE_USER" -m 700 "$ROOT/home" "$ROOT/workspaces"
  install -d -o "$NODE_USER" -g "$NODE_USER" -m 750 "$ROOT/logs"

  step "Kervan code"
  bundle="$(mktemp -d /tmp/kervan-node.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$bundle'" EXIT
  curl -fsSL "$HUB/v1/node/bundle.tar.gz?code=$CODE" | tar -xz -C "$bundle" || fail "couldn't fetch Kervan from the hub. The invite may have expired."
  # Packages install as the node's user, so their install scripts never run as root.
  chown -R "$NODE_USER:$NODE_USER" "$bundle"
  (cd "$bundle" && sudo -H -u "$NODE_USER" env PATH="$path_value" npm ci --omit=dev --no-audit --no-fund --loglevel=error)
  rm -rf "$ROOT/server"
  mv "$bundle" "$ROOT/server"
  trap - EXIT
  # Agents run as the node's user: they can read this code, not change it.
  chown -R root:wheel "$ROOT/server"
  chmod -R go-w "$ROOT/server"
  chmod 755 "$ROOT/server"

  step "joining the hub as '$NAME'"
  local token
  token="$(curl -fsSL -X POST -H 'content-type: application/json' -d "{\"code\":\"$CODE\"}" "$HUB/v1/node/join" \
    | "$node_bin" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).token))')" \
    || fail "the hub refused the invite. Make a new one and run this again."
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || fail "the hub's answer had no usable key."
  (
    umask 077
    {
      echo "KERVAN_HUB_URL=${HUB/#http/ws}"
      echo "KERVAN_NODE_TOKEN=$token"
      echo "KERVAN_NODE_NAME=$NAME"
    } >"$ROOT/node.env"
  )
  chown "$NODE_USER:$NODE_USER" "$ROOT/node.env"
  chmod 600 "$ROOT/node.env"
  # The app shows this; the key file above stays private.
  echo "$NAME" >"$ROOT/node-name"
  chmod 644 "$ROOT/node-name"

  step "service"
  cat >"$ROOT/run-node" <<RUN
#!/bin/bash
set -a
. "$ROOT/node.env"
set +a
export KERVAN_WORKSPACES_DIR="$ROOT/workspaces" KERVAN_NODE_STATE="$ROOT/home/hub.json"
cd "$ROOT/server"
exec "$node_bin" src/node-main.ts
RUN
  chown root:wheel "$ROOT/run-node"
  chmod 755 "$ROOT/run-node"
  cat >"$PLIST" <<PLIST_BODY
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$ROOT/run-node</string></array>
  <key>UserName</key><string>$NODE_USER</string>
  <key>GroupName</key><string>$NODE_USER</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>Umask</key><integer>63</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path_value</string>
    <key>HOME</key><string>$ROOT/home</string>
  </dict>
  <key>StandardOutPath</key><string>$ROOT/logs/node.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/node.log</string>
</dict>
</plist>
PLIST_BODY
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"
  plutil -lint -s "$PLIST"
  launchctl bootstrap system "$PLIST"

  cat <<DONE

Kervan: '$NAME' is installed and connecting to the hub.
Agents on it run as $NODE_USER and can't read your files. To check that: sudo bash "$0" verify
DONE
}

# `caffeinate -s` holds off sleep only on AC power, and nothing here can stop a closed lid or wake a sleeping Mac.
keep_awake() {
  launchctl bootout "system/$AWAKE_LABEL" >/dev/null 2>&1 || true
  rm -f "$AWAKE_PLIST"
  if [[ "$AWAKE" == off ]]; then
    echo "Kervan: this Mac sleeps as usual again."
    return
  fi
  dscl . -read "/Users/$NODE_USER" >/dev/null 2>&1 || fail "this Mac isn't a node yet."
  cat >"$AWAKE_PLIST" <<PLIST_BODY
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AWAKE_LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/caffeinate</string><string>-s</string></array>
  <key>UserName</key><string>$NODE_USER</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST_BODY
  chown root:wheel "$AWAKE_PLIST"
  chmod 644 "$AWAKE_PLIST"
  plutil -lint -s "$AWAKE_PLIST"
  launchctl bootstrap system "$AWAKE_PLIST"
  echo "Kervan: this Mac stays awake while plugged in."
}

# One line per check; exits non-zero when any fails.
check() {
  local what="$1" want="$2" got
  shift 2
  if "$@" >/dev/null 2>&1; then got=yes; else got=no; fi
  if [[ "$got" == "$want" ]]; then
    echo "ok    $what"
  else
    echo "FAIL  $what"
    FAILED=1
  fi
}

as_node() { sudo -H -u "$NODE_USER" "$@"; }

verify_node() {
  FAILED=0
  local person="${SUDO_USER:-}"
  [[ -n "$person" && "$person" != root ]] || fail "run this with sudo from your own account, so your files can be checked."
  local home_dir
  home_dir="$(dscl . -read "/Users/$person" NFSHomeDirectory | awk '{print $2}')"

  check "the service is loaded" yes launchctl print "system/$LABEL"
  check "the service is running" yes bash -c "launchctl print system/$LABEL | grep -q 'state = running'"
  check "$NODE_USER isn't in the staff group" no dseditgroup -o checkmember -m "$NODE_USER" staff
  check "$NODE_USER isn't an administrator" no dseditgroup -o checkmember -m "$NODE_USER" admin
  check "it can't list your home folder" no as_node ls "$home_dir"
  check "it can't list your .ssh folder" no as_node ls "$home_dir/.ssh"
  check "it can't list your Documents" no as_node ls "$home_dir/Documents"
  check "it can't change Kervan's code" no as_node touch "$ROOT/server/package.json"
  check "it can't use sudo" no as_node sudo -n true
  check "it can write in its own folder" yes as_node touch "$ROOT/workspaces/.verify"
  rm -f "$ROOT/workspaces/.verify"
  check "it can reach Ollama on this Mac" yes as_node curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags
  if [[ "$(stat -f '%Sp %Su' "$ROOT/node.env")" == "-rw------- $NODE_USER" ]]; then
    echo "ok    the node's key file is private"
  else
    echo "FAIL  the node's key file is private"
    FAILED=1
  fi
  echo
  echo "Last lines of the node's log (no keys are logged):"
  tail -n 5 "$ROOT/logs/node.log" 2>/dev/null | cut -c1-200 || true
  [[ "$FAILED" -eq 0 ]] || exit 1
}

remove_node() {
  step "stopping the service"
  stop_daemon
  launchctl bootout "system/$AWAKE_LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$AWAKE_PLIST"
  step "removing the user and its files"
  # macOS starts its own helpers for a user once something runs as them, and agents may still be running.
  local uid
  uid="$(id -u "$NODE_USER" 2>/dev/null || true)"
  if [[ -n "$uid" ]]; then
    launchctl bootout "user/$uid" >/dev/null 2>&1 || true
    pkill -9 -u "$uid" >/dev/null 2>&1 || true
  fi
  # The user can't always be deleted at once, while macOS is still ending its helpers.
  local attempt
  for attempt in 1 2 3 4 5; do
    dscl . -read "/Users/$NODE_USER" >/dev/null 2>&1 || break
    dscl . -delete "/Users/$NODE_USER" 2>&1 || true
    [[ -z "$uid" ]] || pkill -9 -u "$uid" >/dev/null 2>&1 || true
    sleep 1
  done
  dscl . -delete "/Groups/$NODE_USER" >/dev/null 2>&1 || true
  rm -rf "${ROOT:?}"
  if dscl . -read "/Users/$NODE_USER" >/dev/null 2>&1; then
    fail "the service and files are gone, but macOS kept the hidden user $NODE_USER. To delete it, run this in Terminal: sudo dscl . -delete /Users/$NODE_USER"
  fi
  echo "Kervan: the node is gone from this Mac. Remove it from the hub in Settings > Nodes too."
}

case "$COMMAND" in
  install) install_node ;;
  verify) verify_node ;;
  remove) remove_node ;;
  keep-awake) keep_awake ;;
esac
