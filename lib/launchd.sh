# shellcheck shell=bash
# lib/launchd.sh — install / uninstall the netdiag launchd watcher plist.
# Run every 15 min in the background, capturing baseline.jsonl over time.
#
# Reads:  LOG_DIR, SCRIPT_PATH, THRESH_WATCHER_INTERVAL_S
# Uses:   watchdog_path_blocked, watchdog_plist_path (lib/watchdog.sh)
# Entry:  install_watcher_run, uninstall_watcher_run (each exits)

install_watcher_run() {
  local plist; plist="$(watchdog_plist_path)"

  # Refuse rather than install something that can never run.
  #
  # This is the whole ND-1 story in one guard. A watcher installed from a
  # checkout under ~/Documents exits 126 on every invocation — launchd
  # agents get no TCC grant for the protected folders and there is no
  # consent prompt to grant one, because the prompt would be attributed
  # to bash. Writing the plist anyway produced 1,386 consecutive silent
  # failures on this developer's machine, with a 0-byte stdout log that
  # looked exactly like health.
  if watchdog_path_blocked "$SCRIPT_PATH"; then
    printf 'watcher not installed.\n\n' >&2
    printf '  netdiag runs from a folder macOS keeps background agents out of:\n' >&2
    printf '    %s\n\n' "$SCRIPT_PATH" >&2
    printf '  A launchd agent gets no access to ~/Documents, ~/Desktop or\n' >&2
    printf '  ~/Downloads, and cannot ask for any — so every scheduled run\n' >&2
    printf '  would fail with "Operation not permitted" and record nothing,\n' >&2
    printf '  while the log it writes stayed empty and looked healthy.\n\n' >&2
    printf '  Install netdiag outside those folders first, then re-run this:\n\n' >&2
    printf '    curl -fsSL %s | bash\n' \
      'https://raw.githubusercontent.com/godigi/netdiag/main/install.sh' >&2
    printf '    netdiag --install-watcher\n\n' >&2
    printf '  That puts the checkout in ~/.local/share/netdiag and repoints\n' >&2
    printf '  the netdiag on your PATH at it. Your reports in %s are\n' "$LOG_DIR" >&2
    printf '  untouched, and this checkout is left exactly as it is.\n' >&2
    exit 3
  fi

  mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
  # NETDIAG_WATCHER is what lets a run know it *is* the watcher, so
  # watchdog_heartbeat records a completed run. Without it the only
  # evidence a watcher ever ran would be launchd's exit status, which
  # says nothing about whether the run reached the end.
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WATCHER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
    <string>--quick</string>
    <string>--no-gping</string>
    <string>--no-bufferbloat</string>
    <string>--quiet</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NETDIAG_WATCHER</key><string>1</string>
  </dict>
  <key>StartInterval</key><integer>$THRESH_WATCHER_INTERVAL_S</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$LOG_DIR/watcher.stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/watcher.stderr.log</string>
</dict>
</plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  printf 'installed: %s (runs every %s min)\n' \
    "$plist" "$(( THRESH_WATCHER_INTERVAL_S / 60 ))"
  printf 'tail log:   tail -f %s/watcher.stdout.log\n' "$LOG_DIR"
  printf 'check on it: netdiag reports ND-1 if it stops running.\n'
  exit 0
}

uninstall_watcher_run() {
  local plist; plist="$(watchdog_plist_path)"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    # The heartbeat is evidence about a watcher that no longer exists.
    # Left behind, a re-install would read it and believe a watcher that
    # has never run once was running until moments ago.
    rm -f "$(watchdog_heartbeat_path)"
    printf 'removed: %s\n' "$plist"
  else
    printf 'no watcher installed at %s\n' "$plist"
  fi
  exit 0
}

# ── The event recorder ───────────────────────────────────────────────────
#
# A KeepAlive agent running one long-lived `--monitor --journal`, so that
# "was the internet down at 03:14, and for how long" has an answer after a
# reboot. The watcher above cannot answer it: it samples every fifteen
# minutes and stores a snapshot, so any outage shorter than its cadence
# happens entirely between two clean runs.
#
# RunAtLoad and KeepAlive, unlike the watcher's StartInterval: this is a
# process that should always be running, and launchd restarting it after a
# crash is the whole point. The journal is append-only across those
# restarts, and helpers/events.py closes any episode still open at a
# restart rather than letting it span a period nobody watched.
#
# stdout goes to /dev/null on purpose. `--monitor` emits a sample every few
# seconds forever; that stream is for a program reading the pipe, and
# writing it to a file would produce hundreds of megabytes to answer
# nothing. The journal is the durable artifact, and it holds transitions.
install_recorder_run() {
  local plist; plist="$(watchdog_recorder_plist_path)"

  if watchdog_path_blocked "$SCRIPT_PATH"; then
    printf 'recorder not installed.\n\n' >&2
    printf '  netdiag runs from a folder macOS keeps background agents out of:\n' >&2
    printf '    %s\n\n' "$SCRIPT_PATH" >&2
    printf '  Same reason as the watcher: a launchd agent gets no access to\n' >&2
    printf '  ~/Documents, ~/Desktop or ~/Downloads and cannot ask for any.\n' >&2
    printf '  Install netdiag outside those folders first, then re-run this.\n' >&2
    exit 3
  fi

  mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$RECORDER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
    <string>--monitor</string>
    <string>--journal</string>
    <string>$LOG_DIR/events.jsonl</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/recorder.stderr.log</string>
</dict>
</plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  printf 'installed: %s\n' "$plist"
  printf 'journal:    %s/events.jsonl\n' "$LOG_DIR"
  printf 'read it:    netdiag --events=24\n'
  exit 0
}

uninstall_recorder_run() {
  local plist; plist="$(watchdog_recorder_plist_path)"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    # The journal is deliberately left in place: it is the record, and
    # uninstalling the thing that writes it is not a request to delete it.
    printf 'removed: %s\n' "$plist"
    printf 'the journal at %s/events.jsonl was left alone.\n' "$LOG_DIR"
  else
    printf 'no recorder installed at %s\n' "$plist"
  fi
  exit 0
}
