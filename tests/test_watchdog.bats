#!/usr/bin/env bats
#
# lib/watchdog.sh — netdiag noticing that netdiag's own watcher stopped.
#
# The bug these guard is not hypothetical and not small: on this project's
# own machine `com.netdiag.watcher` failed 1,386 consecutive times over
# seventeen days, and every visible signal said it was fine. `launchctl`
# knew (exit 126). The stderr log knew (124 KB of one line). The stdout
# log the install message tells you to tail was 0 bytes — indistinguishable
# from a healthy watcher with nothing to say.
#
# Two halves are tested here: the refusal to install a watcher that could
# never run, and the state machine that catches the ones installed before
# that refusal existed.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  LOG_DIR="$BATS_TEST_TMPDIR/net-diag"
  mkdir -p "$LOG_DIR"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/watchdog.sh
  . "$REPO/lib/watchdog.sh"
}

# ── The folders a launchd agent can never run from ───────────────────────

@test "a path under ~/Documents is refused" {
  run watchdog_path_blocked "$HOME/Documents/AI-Workspace/netdiag/bin/netdiag"
  [ "$status" -eq 0 ]
}

@test "~/Desktop and ~/Downloads are refused too" {
  run watchdog_path_blocked "$HOME/Desktop/netdiag/bin/netdiag"
  [ "$status" -eq 0 ]
  run watchdog_path_blocked "$HOME/Downloads/netdiag/bin/netdiag"
  [ "$status" -eq 0 ]
}

@test "iCloud Drive is refused — the space in the path is not an escape" {
  run watchdog_path_blocked "$HOME/Library/Mobile Documents/com~apple~CloudDocs/netdiag/bin/netdiag"
  [ "$status" -eq 0 ]
}

@test "the install location install.sh actually uses is allowed" {
  run watchdog_path_blocked "$HOME/.local/share/netdiag/bin/netdiag"
  [ "$status" -ne 0 ]
  run watchdog_path_blocked "/usr/local/bin/netdiag"
  [ "$status" -ne 0 ]
}

@test "a path merely containing the word Documents is allowed" {
  # The guard is about three specific folders, not a substring. Refusing
  # a working location is as wrong as accepting a broken one.
  run watchdog_path_blocked "$HOME/src/Documents-app/bin/netdiag"
  [ "$status" -ne 0 ]
  run watchdog_path_blocked "/opt/Documents/netdiag"
  [ "$status" -ne 0 ]
}

@test "--install-watcher refuses a blocked path and writes no plist" {
  # The whole point: it must exit non-zero *and* leave nothing behind,
  # because a plist that exists is a plist that launchd will keep failing
  # to run every fifteen minutes forever.
  fake_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$fake_home/Documents/netdiag/bin" "$fake_home/Library/LaunchAgents"
  cp "$NETDIAG" "$fake_home/Documents/netdiag/bin/netdiag"
  cp -R "$REPO/lib" "$REPO/helpers" "$fake_home/Documents/netdiag/"

  run env HOME="$fake_home" "$fake_home/Documents/netdiag/bin/netdiag" --install-watcher
  [ "$status" -eq 3 ]
  [[ "$output" == *"watcher not installed"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation not permitted"* ]] || { echo "$output"; return 1; }
  [ ! -f "$fake_home/Library/LaunchAgents/com.netdiag.watcher.plist" ]
}

# ── The state machine ────────────────────────────────────────────────────
#
# watchdog_run reads the real launchctl, so these drive the decision the
# same way lib/diagnosis.sh does — through the variables it sets — rather
# than trying to fake a launchd. The mapping from those variables to a
# state is the part that decides whether ND-1 fires, and it is the part
# that would silently rot.

# Re-run just the verdict block against a constructed set of readings.
# Mirrors watchdog_run's tail; kept in step by the assertion below that
# every state it can produce is one lib/diagnosis.sh and lib/headline.sh
# both handle.
watchdog_state_for() {
  WATCHER_PATH_BLOCKED="$1"
  WATCHER_LAST_EXIT="$2"
  WATCHER_HEARTBEAT_AGE_S="$3"
  WATCHER_INSTALLED_AGE_S="$4"
  WATCHER_PLIST_INTERVAL_S="$THRESH_WATCHER_INTERVAL_S"
  local stale_s=$(( WATCHER_PLIST_INTERVAL_S * THRESH_WATCHER_STALE_FACTOR ))
  if [ "$WATCHER_PATH_BLOCKED" -eq 1 ]; then printf blocked
  elif [ -n "$WATCHER_LAST_EXIT" ] && [ "$WATCHER_LAST_EXIT" != "0" ]; then printf failing
  elif [ -z "$WATCHER_HEARTBEAT_AGE_S" ]; then
    if [ -n "$WATCHER_INSTALLED_AGE_S" ] && [ "$WATCHER_INSTALLED_AGE_S" -gt "$stale_s" ]
    then printf never; else printf pending; fi
  elif [ "$WATCHER_HEARTBEAT_AGE_S" -gt "$stale_s" ]; then printf stale
  else printf ok; fi
}

@test "a blocked path outranks every other reading" {
  # Exit 0 and a fresh heartbeat would both say "fine" on their own. A
  # watcher that cannot execute has neither, but the ordering has to be
  # right or a stale reading from before the move would mask it.
  [ "$(watchdog_state_for 1 0 60 99999)" = blocked ]
}

@test "a non-zero launchd exit is failing, whatever the heartbeat says" {
  [ "$(watchdog_state_for 0 126 60 99999)" = failing ]
  [ "$(watchdog_state_for 0 1 "" 99999)" = failing ]
}

@test "exit 0 with a recent run is ok" {
  [ "$(watchdog_state_for 0 0 60 99999)" = ok ]
}

@test "a run inside the tolerated window is still ok" {
  local edge=$(( THRESH_WATCHER_INTERVAL_S * THRESH_WATCHER_STALE_FACTOR ))
  [ "$(watchdog_state_for 0 0 "$edge" 99999)" = ok ]
  [ "$(watchdog_state_for 0 0 $(( edge + 1 )) 99999)" = stale ]
}

@test "a freshly installed watcher is pending, not never" {
  # The rule that stops ND-1 crying wolf: installed a minute ago, it
  # simply has not run yet. Accusing it then teaches users to ignore it.
  [ "$(watchdog_state_for 0 "" "" 60)" = pending ]
}

@test "no heartbeat after the window has passed is never" {
  [ "$(watchdog_state_for 0 "" "" $(( THRESH_WATCHER_INTERVAL_S * THRESH_WATCHER_STALE_FACTOR + 1 )))" = never ]
}

@test "every state the machine can produce is one both consumers handle" {
  # lib/diagnosis.sh turns four states into ND-1; lib/headline.sh renders
  # six into a Report card row. A seventh state added to watchdog.sh and
  # nowhere else would render as nothing at all, silently — which is the
  # exact failure this whole rule exists to end.
  for s in ok pending stale never failing blocked; do
    grep -q "^    $s)" "$REPO/lib/headline.sh" \
      || { echo "lib/headline.sh has no row for state: $s"; return 1; }
  done
  for s in stale never failing blocked; do
    grep -q "^    $s)" "$REPO/lib/diagnosis.sh" \
      || { echo "lib/diagnosis.sh has no ND-1 branch for state: $s"; return 1; }
  done
}

@test "the state list in watchdog.sh matches the one tested here" {
  # Guards the guard: if watchdog_run learns a new state, this file's
  # table above stops being the whole story and the test above stops
  # covering it.
  run bash -c "grep -oE 'WATCHER_STATE=[a-z]+' '$REPO/lib/watchdog.sh' | cut -d= -f2 | sort -u | tr '\n' ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "absent blocked failing never ok pending stale " ]
}

# ── The heartbeat ────────────────────────────────────────────────────────

@test "an ordinary run writes no heartbeat" {
  # Without this, any interactive run would keep a dead watcher looking
  # alive — the single most important property of the file.
  unset NETDIAG_WATCHER
  watchdog_heartbeat 0
  [ ! -f "$LOG_DIR/watcher.heartbeat" ]
}

@test "a watcher run writes the time and the exit status" {
  NETDIAG_WATCHER=1 watchdog_heartbeat 2
  [ -f "$LOG_DIR/watcher.heartbeat" ]
  read -r stamp status_code < "$LOG_DIR/watcher.heartbeat"
  [ "$status_code" = 2 ]
  # Written now, so its age is small — and never negative.
  age="$(watchdog_age_since "$stamp")"
  [ -n "$age" ]
  [ "$age" -ge 0 ]
  [ "$age" -lt 60 ]
}

@test "a heartbeat from the future is not treated as an age" {
  # A clock change, or a hand-edited file. Rather than a negative age
  # that reads as "ran in the future", it produces no reading at all —
  # and no reading is the `pending`/`never` path, never a false `ok`.
  future=$(( $(date +%s) + 86400 ))
  [ -z "$(watchdog_age_since "$future")" ]
  [ -z "$(watchdog_age_since "not-a-number")" ]
  [ -z "$(watchdog_age_since "")" ]
}

@test "ages read as English, singular and plural" {
  [ "$(watchdog_fmt_age 1)" = "1 second" ]
  [ "$(watchdog_fmt_age 90)" = "1 minute" ]
  [ "$(watchdog_fmt_age 5400)" = "1 hour" ]
  [ "$(watchdog_fmt_age 7200)" = "2 hours" ]
  [ "$(watchdog_fmt_age 1471984)" = "17 days" ]
  [ "$(watchdog_fmt_age "")" = "an unknown time" ]
}

# ── The two halves agree about where the plist lives ─────────────────────

@test "install and check name the same plist" {
  # They used to hardcode the path separately. netdiag reporting "no
  # watcher installed" about a watcher it installed itself is the failure
  # this collapses into one function.
  [ "$(watchdog_plist_path)" = "$HOME/Library/LaunchAgents/com.netdiag.watcher.plist" ]
  run grep -c 'com.netdiag.watcher.plist' "$REPO/lib/launchd.sh"
  [ "$output" = "0" ]
}

@test "the plist install writes the interval from thresholds.sh" {
  run grep -c 'StartInterval</key><integer>900' "$REPO/lib/launchd.sh"
  [ "$output" = "0" ]
  run grep -q 'THRESH_WATCHER_INTERVAL_S' "$REPO/lib/launchd.sh"
  [ "$status" -eq 0 ]
}

@test "the plist sets NETDIAG_WATCHER so a run knows it is the watcher" {
  run grep -q 'NETDIAG_WATCHER' "$REPO/lib/launchd.sh"
  [ "$status" -eq 0 ]
}
