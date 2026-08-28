# shellcheck shell=bash
# lib/traffic.sh — what on this Mac was using the link while we measured it.
#
# netdiag measures the *path* and has never once measured the traffic on it.
# That gap produces a specific, common, confidently wrong answer: a
# bufferbloat grade of D while Time Machine uploads at 40 Mb/s reads exactly
# like a bufferbloat grade of D on an idle link, and the report blames the
# router's queue in both cases. One of those users needs a better router;
# the other needs to wait ten minutes. Until now they got the same advice.
#
# This file only measures. Whether a number is large enough to matter is
# TR-1's business, in lib/diagnosis.sh, against lib/thresholds.sh.
#
# ── Why it runs inside the parallel batch ──────────────────────────────
# Every other "needs a quiet link" check (internet_ping, bufferbloat) is
# serialised because its own probes are what the quiet is for. This one is
# a *passive observer* — nettop reports other processes' counters and
# generates no traffic of its own — so making it wait would add its whole
# sample window to the run for no gain.
#
# The cost of that is netdiag's own batch traffic landing inside the
# window, which helpers/traffic.py excludes by process name (its SELF set).
# Without that exclusion netdiag would report itself as the busiest thing
# on the link on every single run.
#
# ── Why --quick skips it ───────────────────────────────────────────────
# nettop needs ~3 s of startup before its first snapshot, so even a 1 s
# window costs 4-5 s of wall clock. The --quick budget is 8 s total. A
# check that eats half of it to answer a question --quick did not ask is
# the wrong trade, and the watcher (which runs --quick) is the one caller
# where the omission matters least: it is sampling every fifteen minutes.
#
# Reads:  QUICK, THRESH_TRAFFIC_SAMPLE_S
# Writes: TRAFFIC_MEASURED, TRAFFIC_DOWN_MBPS, TRAFFIC_UP_MBPS,
#         TRAFFIC_TOP_JSON, TRAFFIC_TOP_NAME, TRAFFIC_SAMPLED_S
# Entry:  traffic_run
#
# Read across modules that shellcheck can't follow from here.
# shellcheck disable=SC2034

# Persist across the launch_parallel subshell boundary. Called on every
# exit path, including the ones that measured nothing: a check that runs
# and finds nothing must write that down, or the parent keeps whatever it
# had and the difference between "measured zero" and "never ran" is lost.
traffic_persist() {
  setvar TRAFFIC_MEASURED   "$TRAFFIC_MEASURED"
  setvar TRAFFIC_DOWN_MBPS  "$TRAFFIC_DOWN_MBPS"
  setvar TRAFFIC_UP_MBPS    "$TRAFFIC_UP_MBPS"
  setvar TRAFFIC_SAMPLED_S  "$TRAFFIC_SAMPLED_S"
  setvar TRAFFIC_TOP_NAME   "$TRAFFIC_TOP_NAME"
  setvar TRAFFIC_TOP_JSON   "$TRAFFIC_TOP_JSON"
}

traffic_run() {
  TRAFFIC_MEASURED=0
  TRAFFIC_DOWN_MBPS=""
  TRAFFIC_UP_MBPS=""
  TRAFFIC_TOP_JSON="[]"
  TRAFFIC_TOP_NAME=""
  TRAFFIC_SAMPLED_S=""

  if [ "$QUICK" -eq 1 ]; then
    progress_skip "--quick"
    traffic_persist
    return 0
  fi
  if ! command -v nettop >/dev/null 2>&1; then
    progress_skip "nettop not available"
    traffic_persist
    return 0
  fi

  hdr "Local traffic"

  local secs="$THRESH_TRAFFIC_SAMPLE_S" raw json
  # -L 2 gives two cumulative snapshots -s seconds apart; -P aggregates by
  # process; -x keeps the output machine-readable. The timeout is generous
  # because nettop's own startup dominates the window.
  raw="$(with_timeout $(( secs + 10 )) \
    nettop -P -x -J bytes_in,bytes_out -L 2 -s "$secs" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    info "nettop returned nothing — traffic not measured."
    traffic_persist
    return 0
  fi

  json="$(printf '%s\n' "$raw" | python3 "$HELPERS_DIR/traffic.py" "$secs" 2>/dev/null || true)"
  if [ -z "$json" ]; then
    info "could not parse nettop output — traffic not measured."
    traffic_persist
    return 0
  fi

  # One python invocation to lift the fields out, rather than five: the
  # helper already produced the JSON and re-parsing it per field is the
  # kind of cost that only looks small.
  local parsed
  parsed="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("measured"):
    print("0")
    raise SystemExit(0)
top = d.get("top_processes") or []
print("1")
print(d.get("down_mbps", ""))
print(d.get("up_mbps", ""))
print(d.get("sampled_s", ""))
print(top[0]["name"] if top else "")
print(json.dumps(top, separators=(",", ":")))
' 2>/dev/null || true)"

  [ -n "$parsed" ] || { info "could not read the traffic sample."; traffic_persist; return 0; }

  {
    read -r TRAFFIC_MEASURED
    read -r TRAFFIC_DOWN_MBPS
    read -r TRAFFIC_UP_MBPS
    read -r TRAFFIC_SAMPLED_S
    read -r TRAFFIC_TOP_NAME
    read -r TRAFFIC_TOP_JSON
  } <<< "$parsed"
  TRAFFIC_TOP_JSON="${TRAFFIC_TOP_JSON:-[]}"

  if [ "$TRAFFIC_MEASURED" != "1" ]; then
    TRAFFIC_MEASURED=0
    info "nettop gave only one snapshot — traffic not measured."
    traffic_persist
    return 0
  fi

  info "over ${TRAFFIC_SAMPLED_S}s: ${TRAFFIC_DOWN_MBPS} Mb/s down, ${TRAFFIC_UP_MBPS} Mb/s up (excluding netdiag's own probes)"
  if [ -n "$TRAFFIC_TOP_NAME" ]; then
    info "busiest process: $TRAFFIC_TOP_NAME"
  fi
  traffic_persist
  return 0
}

# True when either direction is carrying at least $1 Mb/s. Kept here rather
# than inline in diagnosis.sh so the comparison against a float happens in
# one place — bash cannot compare "12.16" with [ -gt ] at all, and the awk
# that can is easy to get subtly wrong twice.
traffic_at_least() {
  local floor="$1"
  [ "${TRAFFIC_MEASURED:-0}" -eq 1 ] || return 1
  awk -v d="${TRAFFIC_DOWN_MBPS:-0}" -v u="${TRAFFIC_UP_MBPS:-0}" -v f="$floor" \
    'BEGIN { exit !(d >= f || u >= f) }'
}

# The busier direction, as "N Mb/s up" / "N Mb/s down", for a sentence.
traffic_busier_direction() {
  awk -v d="${TRAFFIC_DOWN_MBPS:-0}" -v u="${TRAFFIC_UP_MBPS:-0}" \
    'BEGIN { if (u > d) printf "%g Mb/s up", u; else printf "%g Mb/s down", d }'
}
