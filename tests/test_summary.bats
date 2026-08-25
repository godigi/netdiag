#!/usr/bin/env bats
#
# `netdiag --summary` — the aggregate over ~/net-diag/baseline.jsonl.
#
# This surface had drifted furthest from the rest of the tool: it blended
# every network into one distribution, summed a rolling one-hour window
# across overlapping runs, and printed numbers without judging any of
# them. These tests pin the corrected behaviour.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  STORE="$BATS_TEST_TMPDIR/baseline.jsonl"
  : > "$STORE"
}

# Append one record. $1 timestamp, $2 network id, $3.. extra JSON fragments.
rec() {
  local ts="$1" nid="$2"; shift 2
  local extra=""
  for frag in "$@"; do extra="${extra},${frag}"; done
  printf '{"timestamp":"%s","network":{"id":"%s"}%s}\n' "$ts" "$nid" "$extra" >> "$STORE"
}

# Run summary.py directly with a wide window so fixture timestamps land
# inside it regardless of when the suite runs.
summarise() {
  python3 "$REPO/helpers/summary.py" --history "$STORE" --window "${1:-999999}"
}

# A timestamp inside any sane window — "now", so --window always covers it.
now_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

@test "a single-sample metric says 'sample', not 'samples'" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"(1 sample)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"(1 samples)"* ]] || { echo "$output"; return 1; }
}

@test "two samples still say 'samples'" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":7.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"(2 samples)"* ]] || { echo "$output"; return 1; }
}

@test "a long diagnosis is wrapped, not cut off mid-advice" {
  # The CLI writes the fix into the second half of the sentence. Cutting
  # at 80 characters reliably threw the actionable part away.
  local long='Your Mac is losing packets to your router and the fix is to unplug the router for thirty seconds and plug it back in again'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    "\"diagnosis\":[{\"severity\":\"critical\",\"summary\":\"$long\"}]"
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" != *"…"* ]] || { echo "still truncating:"; echo "$output"; return 1; }
  [[ "$output" == *"plug it back in again"* ]] || {
    echo "the advice did not survive:"; echo "$output"; return 1
  }
}

@test "disconnects report the busiest single run, never a sum" {
  # wifi_disconnects.count covers a rolling 1h window
  # (WIFI_DISCONNECT_WINDOW_HOURS in lib/globals.sh) and is recomputed
  # per run. Three runs 15 minutes apart, each seeing the same 5
  # events, describe 5 disconnects — not 15.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" != *"15"* ]] || { echo "still summing:"; echo "$output"; return 1; }
  [[ "$output" == *"busiest hour"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"5 disconnect"* ]] || { echo "$output"; return 1; }
}

@test "no disconnect data at all says so rather than reporting zero" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"no data"* ]] || { echo "$output"; return 1; }
}
