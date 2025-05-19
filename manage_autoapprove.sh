#!/usr/bin/env bash
set -euo pipefail

# Prevent running as root
if [[ "$EUID" -eq 0 ]]; then
  echo "[!] Do not run this script as root or with sudo."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/auto_approve.sh"
LABEL="com.tf-agcdn-auto-approve"
PLIST_NAME="$LABEL.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/autoapprove.log"
ERRFILE="$SCRIPT_DIR/autoapprove.err"

function install() {
  echo "[*] Installing dependencies..."
  brew install gh jq

  if ! gh auth status &>/dev/null; then
    echo "[*] GitHub CLI not authenticated. Starting auth flow..."
    gh auth login
  fi

  echo "[*] Creating launch agent plist at $PLIST_PATH..."
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOGFILE</string>
  <key>StandardErrorPath</key>
  <string>$ERRFILE</string>
</dict>
</plist>
EOF

  echo "[*] Bootstrapping launch agent..."
  launchctl bootstrap gui/$(id -u) "$PLIST_PATH"
  echo "[✓] Auto-approval job installed."
}

function uninstall() {
  echo "[*] Stopping launch agent..."
  launchctl bootout gui/$(id -u) "$PLIST_PATH" || echo "[!] Agent may not have been loaded."
  echo "[*] Removing plist file..."
  rm -f "$PLIST_PATH"
  echo "[*] Done. Auto-approval job uninstalled."
}

function start() {
  if launchctl list | grep -q "$LABEL"; then
    echo "[✓] Launch agent already running."
    return
  fi
  echo "[*] Starting launch agent..."
  launchctl bootstrap gui/$(id -u) "$PLIST_PATH"
}

function stop() {
  echo "[*] Stopping launch agent..."
  launchctl bootout gui/$(id -u) "$PLIST_PATH"
}

function reload() {
  echo "[*] Reloading launch agent..."
  stop || true
  start
}

function status() {
  local output
  output=$(launchctl list | grep "$LABEL" || true)
  if [[ -z "$output" ]]; then
    echo "[!] Launch agent '$LABEL' is not loaded."
  elif echo "$output" | grep -q '^-' ; then
    echo "[✓] Launch agent '$LABEL' is loaded but not currently running (likely between intervals)."
  else
    echo "[✓] Launch agent '$LABEL' is running or recently launched."
  fi
}

function logs() {
  echo "[*] Tailing logs... Press Ctrl+C to exit."
  tail -n20 -f "$LOGFILE" "$ERRFILE"
}

case "${1:-}" in
  install)
    install
    ;;
  uninstall)
    uninstall
    ;;
  start)
    start
    ;;
  stop)
    stop
    ;;
  reload)
    reload
    ;;
  status)
    status
    ;;
  logs)
    logs
    ;;
  *)
    echo "Usage: $0 {install|uninstall|start|stop|reload|status|logs}"
    exit 1
    ;;
esac
