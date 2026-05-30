# shellcheck shell=bash
# lib/launchd.sh — install / uninstall the netdiag launchd watcher plist.
# Run every 15 min in the background, capturing baseline.jsonl over time.
#
# Reads:  LOG_DIR, SCRIPT_PATH
# Entry:  install_watcher_run, uninstall_watcher_run (each exits)

install_watcher_run() {
  mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
  local plist="$HOME/Library/LaunchAgents/com.netdiag.watcher.plist"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.netdiag.watcher</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
    <string>--quick</string>
    <string>--no-gping</string>
    <string>--no-bufferbloat</string>
    <string>--quiet</string>
  </array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$LOG_DIR/watcher.stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/watcher.stderr.log</string>
</dict>
</plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  printf 'installed: %s (runs every 15 min)\n' "$plist"
  printf 'tail log:   tail -f %s/watcher.stdout.log\n' "$LOG_DIR"
  exit 0
}

uninstall_watcher_run() {
  local plist="$HOME/Library/LaunchAgents/com.netdiag.watcher.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    printf 'removed: %s\n' "$plist"
  else
    printf 'no watcher installed at %s\n' "$plist"
  fi
  exit 0
}
