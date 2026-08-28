# shellcheck shell=bash
# lib/watchdog.sh — is netdiag's own background watcher actually running?
#
# Why this file exists, in one number: **1,386**. That is how many times
# `com.netdiag.watcher` failed on this developer's machine, once every
# fifteen minutes from 11 August to 28 August, without netdiag ever
# saying so. `launchctl list` reported exit status 126 the whole time,
# `watcher.stderr.log` filled with 124 KB of one repeated line, and
# `watcher.stdout.log` sat at 0 bytes — which is exactly what a healthy,
# quiet watcher looks like.
#
# The cause is TCC, and it is not developer-specific. The plist points at
# whatever `netdiag` on PATH resolves to; `install.sh`, run from inside a
# clone, deliberately points that symlink at the clone; and a launchd
# agent has no consent grant for `~/Documents`, `~/Desktop` or
# `~/Downloads`. Clone netdiag into any of the three, install from it,
# and the watcher can never execute — silently, forever.
#
# So this module answers two questions a run should never have to be
# asked twice: is a watcher installed, and has it actually run recently?
# Both are local — one plist read, one `launchctl list`, one file mtime.
# No network traffic, and nothing here judges the network.
#
# Reads:  LOG_DIR, HOME
# Writes: WATCHER_INSTALLED, WATCHER_PROGRAM, WATCHER_PLIST_INTERVAL_S,
#         WATCHER_LAST_EXIT, WATCHER_HEARTBEAT_AT, WATCHER_HEARTBEAT_AGE_S,
#         WATCHER_PATH_BLOCKED, WATCHER_INSTALLED_AGE_S, WATCHER_STATE
# Entry:  watchdog_run, watchdog_heartbeat
#
# Read across modules that shellcheck can't follow from here.
# shellcheck disable=SC2034

WATCHER_LABEL="com.netdiag.watcher"

# The one place either half of the feature names the plist. lib/launchd.sh
# writes it, watchdog_run reads it, and a mismatch would mean netdiag
# cheerfully reporting "no watcher installed" about a watcher it installed
# itself.
watchdog_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$WATCHER_LABEL"
}

watchdog_heartbeat_path() {
  printf '%s/watcher.heartbeat' "${LOG_DIR:-$HOME/net-diag}"
}

# True when $1 sits under a folder macOS guards with TCC.
#
# A launchd agent cannot be granted access to these by consent: the
# prompt is attributed to the *executable*, which for the watcher is
# Homebrew's bash, and telling a user to give bash Full Disk Access to
# fix a network tool is worse advice than not shipping the watcher at
# all. Refusing the install is the honest option.
#
# The list is deliberately the three folders with a per-app TCC gate plus
# iCloud Drive, not every path that might fail — a guess that refuses a
# working location is as bad as one that accepts a broken one.
watchdog_path_blocked() {
  case "$1" in
    "$HOME"/Documents/*|"$HOME"/Documents) return 0 ;;
    "$HOME"/Desktop/*|"$HOME"/Desktop) return 0 ;;
    "$HOME"/Downloads/*|"$HOME"/Downloads) return 0 ;;
    "$HOME/Library/Mobile Documents/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Record that the watcher completed a run. Called from bin/netdiag's exit
# path, and only when the run *is* the watcher — the plist sets
# NETDIAG_WATCHER=1, so an ordinary interactive run never touches the
# file and can never make a dead watcher look alive.
#
# The file carries the exit status as well as the time, because "ran, and
# reported a critical" and "ran, all clear" are both healthy watcher
# states and a reader should not have to infer which from silence. $1 is
# the run's exit status.
watchdog_heartbeat() {
  [ "${NETDIAG_WATCHER:-0}" = "1" ] || return 0
  mkdir -p "${LOG_DIR:-$HOME/net-diag}" 2>/dev/null || return 0
  printf '%s %s\n' "$(date +%s)" "${1:-0}" \
    > "$(watchdog_heartbeat_path)" 2>/dev/null || true
  return 0
}

# A duration in seconds ($1) as something a person reads: "9 minutes",
# "3 hours", "17 days". Coarse on purpose — ND-1's sentence is about
# whether a watcher has stopped, and "16 days, 4 hours and 11 minutes"
# spends precision on a question nobody asked.
watchdog_fmt_age() {
  local s="${1:-}"
  case "$s" in
    ''|*[!0-9]*) printf 'an unknown time'; return 0 ;;
  esac
  local n unit
  if   [ "$s" -lt 60 ];    then n="$s";               unit=second
  elif [ "$s" -lt 3600 ];  then n=$(( s / 60 ));      unit=minute
  elif [ "$s" -lt 86400 ]; then n=$(( s / 3600 ));    unit=hour
  else                          n=$(( s / 86400 ));   unit=day
  fi
  printf '%s %s%s' "$n" "$unit" "$([ "$n" -eq 1 ] || printf s)"
}

# Seconds since the epoch timestamp in $1, or "" if it is not a number.
# Guards against a hand-edited or truncated heartbeat producing a
# negative age that would read as "ran in the future".
watchdog_age_since() {
  case "$1" in
    ''|*[!0-9]*) return 0 ;;
  esac
  local now; now="$(date +%s)"
  [ "$1" -le "$now" ] || return 0
  printf '%s' "$(( now - $1 ))"
}

watchdog_run() {
  WATCHER_INSTALLED=0
  WATCHER_PROGRAM=""
  WATCHER_PLIST_INTERVAL_S=""
  WATCHER_LAST_EXIT=""
  WATCHER_HEARTBEAT_AT=""
  WATCHER_HEARTBEAT_AGE_S=""
  WATCHER_INSTALLED_AGE_S=""
  WATCHER_PATH_BLOCKED=0
  WATCHER_STATE=absent

  local plist; plist="$(watchdog_plist_path)"
  if [ ! -f "$plist" ]; then
    # Not installed is not a fault and gets no section: the overwhelming
    # majority of runs are interactive, and a "Background watcher: not
    # installed" header in every one of them is an advertisement, not a
    # diagnostic.
    progress_skip "no watcher installed"
    return 0
  fi
  WATCHER_INSTALLED=1

  hdr "Background watcher"

  WATCHER_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \
    "$plist" 2>/dev/null || true)"
  WATCHER_PLIST_INTERVAL_S="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' \
    "$plist" 2>/dev/null || true)"
  case "$WATCHER_PLIST_INTERVAL_S" in
    ''|*[!0-9]*) WATCHER_PLIST_INTERVAL_S="$THRESH_WATCHER_INTERVAL_S" ;;
  esac

  # An `if`, not a `[ … ] && … && assign` chain. Under `set -e` bash does
  # not abort on a failing member of an AND-list (verified against the
  # chain this replaced, which survives `set -eu` intact) — but such a
  # chain still *evaluates to* the failure, so it silently becomes the
  # function's return value if it ever ends up last, which is the shape
  # add_diag's header documents biting this project once already. An `if`
  # cannot acquire that property by being moved.
  if [ -n "$WATCHER_PROGRAM" ] && watchdog_path_blocked "$WATCHER_PROGRAM"; then
    WATCHER_PATH_BLOCKED=1
  fi

  # Column 2 of `launchctl list` is the last exit status; column 1 is the
  # PID, or "-" when the job is not currently running. An interval job is
  # not running almost all of the time, so the PID says nothing and the
  # status says everything.
  WATCHER_LAST_EXIT="$(launchctl list 2>/dev/null \
    | awk -v l="$WATCHER_LABEL" '$3 == l { print $2; exit }' || true)"
  case "$WATCHER_LAST_EXIT" in
    ''|*[!0-9-]*) WATCHER_LAST_EXIT="" ;;
  esac

  local hb; hb="$(watchdog_heartbeat_path)"
  if [ -f "$hb" ]; then
    WATCHER_HEARTBEAT_AT="$(awk 'NR==1{print $1}' "$hb" 2>/dev/null || true)"
    WATCHER_HEARTBEAT_AGE_S="$(watchdog_age_since "$WATCHER_HEARTBEAT_AT")"
  fi

  # How long the plist has existed, so a watcher installed thirty seconds
  # ago is not accused of having stopped. `stat -f %m` is BSD stat, which
  # is the only stat on macOS.
  WATCHER_INSTALLED_AGE_S="$(watchdog_age_since \
    "$(stat -f %m "$plist" 2>/dev/null || true)")"

  # One verdict, decided once. The Report card row and ND-1 both describe
  # this state, and if they decided it separately they could disagree —
  # a green "Background watcher: running" over a warning that says it has
  # not run for a fortnight is the exact contradiction lib/thresholds.sh
  # exists to prevent, one level up from a number.
  #
  #   blocked — installed somewhere it can never execute
  #   failing — launchd ran it and it exited non-zero
  #   never   — installed long enough to have run, and never has
  #   stale   — ran once, but not recently enough
  #   pending — installed too recently to have run yet
  #   ok      — completed a run within the tolerated window
  local stale_s
  stale_s=$(( WATCHER_PLIST_INTERVAL_S * THRESH_WATCHER_STALE_FACTOR ))
  if [ "$WATCHER_PATH_BLOCKED" -eq 1 ]; then
    WATCHER_STATE=blocked
  elif [ -n "$WATCHER_LAST_EXIT" ] && [ "$WATCHER_LAST_EXIT" != "0" ]; then
    WATCHER_STATE=failing
  elif [ -z "$WATCHER_HEARTBEAT_AGE_S" ]; then
    if [ -n "$WATCHER_INSTALLED_AGE_S" ] \
       && [ "$WATCHER_INSTALLED_AGE_S" -gt "$stale_s" ]; then
      WATCHER_STATE=never
    else
      WATCHER_STATE=pending
    fi
  elif [ "$WATCHER_HEARTBEAT_AGE_S" -gt "$stale_s" ]; then
    WATCHER_STATE=stale
  else
    WATCHER_STATE=ok
  fi

  info "plist:     $plist"
  if [ -n "$WATCHER_PROGRAM" ]; then info "runs:      $WATCHER_PROGRAM"; fi
  info "every:     ${WATCHER_PLIST_INTERVAL_S}s"
  if [ -n "$WATCHER_LAST_EXIT" ]; then
    info "last exit: $WATCHER_LAST_EXIT"
  else
    info "last exit: not loaded into launchd"
  fi
  if [ -n "$WATCHER_HEARTBEAT_AGE_S" ]; then
    info "last ran:  $(watchdog_fmt_age "$WATCHER_HEARTBEAT_AGE_S") ago"
  else
    info "last ran:  never (no heartbeat recorded)"
  fi
  return 0
}
