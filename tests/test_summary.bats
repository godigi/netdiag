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

@test "two networks get two blocks, and their metrics do not mix" {
  # Everything else in this tool is per-network — baselines, --show's
  # comparison, the Networks tab. A blended min/med/max across home and
  # a cafe describes neither.
  rec "$(now_ts)" "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:ssid=Cafe,mac=11:22:33:44:55:66" '"gateway":{"rtt_avg_ms":90.0}'
  run summarise
  [ "$status" -eq 0 ]
  local headings
  headings="$(printf '%s\n' "$output" | grep -c '^── ')"
  [ "$headings" = "2" ] || { echo "expected 2 network blocks, got $headings"; echo "$output"; return 1; }
  local home_block
  home_block="$(printf '%s\n' "$output" | awk '/^── .*Home/{f=1;next} /^── /{f=0} f')"
  [[ "$home_block" != *"90.0"* ]] || {
    echo "the cafe's RTT leaked into Home's distribution:"; echo "$home_block"; return 1
  }
}

@test "runs recorded under --redact are excluded, as they are from --history" {
  # A masked record's network.id is the literal 'wifi:mac=[redacted]',
  # shared with every other redacted run on every machine. history.py
  # drops these for that reason; summary must agree or the two disagree
  # about what a network is.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:mac=[redacted]" '"gateway":{"rtt_avg_ms":999.0}'
  # An explicit, non-default window: summarise()'s default of 999999 hours
  # prints "last 999999h" in the header, which itself contains "999" and
  # would make the assertion below fail regardless of whether the redacted
  # run's RTT leaked through. now_ts() is always "now", so 24h still covers
  # the fixture.
  run summarise 24
  [ "$status" -eq 0 ]
  [[ "$output" != *"999"* ]] || { echo "a redacted run was counted:"; echo "$output"; return 1; }
}

@test "a network with only redacted runs leaves nothing to report" {
  rec "$(now_ts)" "wifi:mac=[redacted]" '"gateway":{"rtt_avg_ms":999.0}'
  # See the previous test for why the window must be explicit here too.
  run summarise 24
  [ "$status" -eq 0 ]
  [[ "$output" != *"999"* ]] || { echo "$output"; return 1; }
}

@test "the header counts both runs and networks" {
  rec "$(now_ts)" "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:ssid=Cafe,mac=11:22:33:44:55:66" '"gateway":{"rtt_avg_ms":90.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 runs"* ]]     || { echo "$output"; return 1; }
  [[ "$output" == *"2 networks"* ]] || { echo "$output"; return 1; }
}

@test "a network is labelled by its own name, not its group key" {
  rec "$(now_ts)" "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff" \
    '"network":{"id":"wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff","label":"Home"}' \
    '"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"── Home"* ]] || { echo "$output"; return 1; }
}
