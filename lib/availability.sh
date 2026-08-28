# shellcheck shell=bash
# lib/availability.sh — how often, and for how long, this network was down.
#
# The judging half of the event journal. `helpers/events.py` pairs faults
# into episodes and refuses to say whether any of it was bad; this file
# reads those episodes and applies the cutoffs in lib/thresholds.sh, so
# `AV-1` and `AV-2` fire from lib/diagnosis.sh like every other rule.
#
# Why a scan reads a journal at all: a run is a snapshot, and a snapshot
# taken at a good moment on a connection that dropped six times last night
# reports a healthy network — truthfully, and uselessly. The journal is the
# only place that memory exists.
#
# ── Two honesty rules this file exists to keep ─────────────────────────
#
# 1. **Only this network.** Episodes are filtered to NETWORK_ID. A laptop
#    that was on a café's broken WiFi yesterday must not have that counted
#    against the office connection it is on now — the whole reason
#    lib/netid.sh exists.
#
# 2. **Say when the window was not watched.** The recorder pauses for
#    sleep, and a Mac that spent eighteen hours shut has a 24-hour window
#    that is mostly guesswork. The counts stay (an outage that was seen
#    did happen) but the sentence says what fraction was observed, because
#    "no outages in 24 hours" from six hours of watching is a claim the
#    run never established.
#
# Reads:  LOG_DIR, NETWORK_ID, HELPERS_DIR, THRESH_AV_*
# Writes: AV_MEASURED, AV_WINDOW_HOURS, AV_OUTAGE_COUNT, AV_DOWNTIME_S,
#         AV_FLAP_COUNT, AV_UNOBSERVED_PCT, AV_LONGEST_S
# Entry:  availability_run
#
# Read across modules that shellcheck can't follow from here.
# shellcheck disable=SC2034

availability_run() {
  AV_MEASURED=0
  AV_WINDOW_HOURS="$THRESH_AV_WINDOW_HOURS"
  AV_OUTAGE_COUNT=0
  AV_DOWNTIME_S=0
  AV_FLAP_COUNT=0
  AV_LONGEST_S=0
  AV_UNOBSERVED_PCT=0

  local journal="$LOG_DIR/events.jsonl"
  if [ ! -s "$journal" ]; then
    # No journal is not "no outages". Without a recorder there is no
    # record, and a rule that fired on its absence would be reporting
    # silence as health — the exact failure ND-1 exists to catch.
    progress_skip "no event journal (netdiag --install-recorder)"
    return 0
  fi
  if [ -z "${NETWORK_ID:-}" ]; then
    progress_skip "network not identified"
    return 0
  fi

  hdr "Availability"

  local parsed
  parsed="$(python3 "$HELPERS_DIR/events.py" \
      --journal "$journal" --hours "$THRESH_AV_WINDOW_HOURS" 2>/dev/null \
    | NETDIAG_AV_NETWORK="$NETWORK_ID" \
      NETDIAG_AV_OUTAGE_RULES="$THRESH_AV_OUTAGE_RULES" \
      NETDIAG_AV_FLAP_MAX_S="$THRESH_AV_FLAP_MAX_S" \
      python3 -c '
import json, os, sys

# Reads the reader'"'"'s output; applies no cutoff of its own. Every number
# it compares against arrives from lib/thresholds.sh through the
# environment, the same contract helpers/history.py works under.
try:
    d = json.load(sys.stdin)
except ValueError:
    raise SystemExit(1)

network = os.environ.get("NETDIAG_AV_NETWORK", "")
outage_rules = set((os.environ.get("NETDIAG_AV_OUTAGE_RULES") or "").split())
try:
    flap_max = int(os.environ.get("NETDIAG_AV_FLAP_MAX_S", "0"))
except ValueError:
    flap_max = 0

episodes = [e for e in d.get("episodes", [])
            if e.get("network") == network and e.get("rule") in outage_rules]
durations = [int(e.get("duration_s") or 0) for e in episodes]
flaps = [s for s in durations if 0 < s <= flap_max] if flap_max else []

frac = (d.get("observation") or {}).get("unobserved_fraction")
print(len(episodes))
print(sum(durations))
print(max(durations) if durations else 0)
print(len(flaps))
print(int(round((frac or 0) * 100)))
' 2>/dev/null || true)"

  if [ -z "$parsed" ]; then
    info "could not read the event journal — availability not judged."
    return 0
  fi

  {
    read -r AV_OUTAGE_COUNT
    read -r AV_DOWNTIME_S
    read -r AV_LONGEST_S
    read -r AV_FLAP_COUNT
    read -r AV_UNOBSERVED_PCT
  } <<< "$parsed"

  # A missing field means the pipeline half-failed; treat the whole
  # reading as absent rather than judging a partial one.
  case "${AV_UNOBSERVED_PCT:-}" in
    ''|*[!0-9]*) info "incomplete reading from the journal — not judged."; return 0 ;;
  esac
  AV_MEASURED=1

  info "last ${AV_WINDOW_HOURS}h on this network: ${AV_OUTAGE_COUNT} outage(s), ${AV_DOWNTIME_S}s total, longest ${AV_LONGEST_S}s"
  info "window unobserved: ${AV_UNOBSERVED_PCT}%"
  return 0
}

# "4 minutes 25 seconds" from a count of seconds, for a sentence a person
# reads. Coarse above an hour: the question AV-1 answers is "how bad", not
# "how long exactly".
availability_fmt_duration() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return 0 ;; esac
  if [ "$s" -lt 60 ]; then
    printf '%s second%s' "$s" "$([ "$s" -eq 1 ] || printf s)"
  elif [ "$s" -lt 3600 ]; then
    local m=$(( s / 60 )) r=$(( s % 60 ))
    printf '%s minute%s' "$m" "$([ "$m" -eq 1 ] || printf s)"
    [ "$r" -gt 0 ] && printf ' %s second%s' "$r" "$([ "$r" -eq 1 ] || printf s)"
  else
    local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 ))
    printf '%s hour%s' "$h" "$([ "$h" -eq 1 ] || printf s)"
    [ "$m" -gt 0 ] && printf ' %s minute%s' "$m" "$([ "$m" -eq 1 ] || printf s)"
  fi
  return 0
}

# The clause AV-1 and AV-2 append when a material part of the window went
# unwatched. Empty otherwise, so the ordinary sentence carries no caveat
# nobody needed.
availability_observation_note() {
  [ "${AV_MEASURED:-0}" -eq 1 ] || return 0
  [ "$AV_UNOBSERVED_PCT" -ge "$THRESH_AV_UNOBSERVED_NOTE_PCT" ] || return 0
  printf ' Note that %s%% of that window was not observed — the Mac was asleep or the recorder was not running — so these are the outages that were *seen*, and there may have been more.' \
    "$AV_UNOBSERVED_PCT"
}
