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
  # Every network block now judges its metrics, so every invocation needs
  # the cutoffs in the environment — the same handshake summarise_judged()
  # below uses. This helper predates that requirement; it still needs to
  # satisfy it, or every pre-existing format/labelling test here would fail
  # on the refusal path instead of exercising what it actually tests.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export LOSS_WARN_PCT LOSS_CRIT_PCT THRESH_BUFFERBLOAT_B_MS \
         THRESH_BUFFERBLOAT_C_MS THRESH_WIFI_RSSI_WEAK_DBM \
         THRESH_WIFI_RSSI_G1_DBM THRESH_MTU_STANDARD THRESH_MTU_CRIT \
         THRESH_NTP_DRIFT_WARN_S THRESH_NTP_DRIFT_CRIT_S
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

# Judging needs the cutoffs, which arrive through the environment exactly
# as history.py's do.
summarise_judged() {
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export LOSS_WARN_PCT LOSS_CRIT_PCT THRESH_BUFFERBLOAT_B_MS \
         THRESH_BUFFERBLOAT_C_MS THRESH_WIFI_RSSI_WEAK_DBM \
         THRESH_WIFI_RSSI_G1_DBM THRESH_MTU_STANDARD THRESH_MTU_CRIT \
         THRESH_NTP_DRIFT_WARN_S THRESH_NTP_DRIFT_CRIT_S
  python3 "$REPO/helpers/summary.py" --history "$STORE" --window "${1:-24}"
}

@test "a clean metric is marked clean" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"✓"* ]] || { echo "$line"; return 1; }
}

@test "a metric whose median is past the critical cutoff is marked critical" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":100.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"×"* ]] || { echo "$line"; return 1; }
}

@test "a clean median with a bad max says so on the same line" {
  # The glyph judges the median — the typical case — but a run that hit
  # 100% loss is the thing the user came to find, so the max is named.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":100.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"✓"* ]] || { echo "median is clean, expected a tick: $line"; return 1; }
  [[ "$line" == *"max"* ]] || { echo "the 100% run was not named: $line"; return 1; }
}

@test "a metric with no samples takes no glyph at all" {
  # Absence of a measurement is not a verdict — the same rule the Report
  # card's grey minus.circle follows.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'NTP drift')"
  [[ "$line" == *"no data"* ]] || { echo "$line"; return 1; }
  [[ "$line" != *"✓"* ]] || { echo "unmeasured metric claimed health: $line"; return 1; }
}

@test "a weak-but-not-terrible RSSI lands in the warn band, not critical" {
  # -72 dBm is worse than G1's -70 but better than W1's -75. If the two
  # cutoffs are assigned to warn/crit the wrong way round, every reading
  # below -70 reads critical and this band becomes unreachable.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi":{"rssi":-72}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'RSSI')"
  [[ "$line" == *"⚠"* ]] || { echo "expected a warn glyph: $line"; return 1; }
  [[ "$line" != *"×"* ]] || { echo "-72 dBm should not be critical: $line"; return 1; }
}

@test "a genuinely bad RSSI is critical" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi":{"rssi":-85}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'RSSI')"
  [[ "$line" == *"×"* ]] || { echo "$line"; return 1; }
}

@test "summary.py refuses to judge without the thresholds" {
  # Same contract history.py holds: a Python default would be a second
  # home for a number that has exactly one, and a stale second copy
  # still produces a plausible verdict.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run env -u LOSS_WARN_PCT -u LOSS_CRIT_PCT \
    python3 "$REPO/helpers/summary.py" --history "$STORE" --window 24
  [ "$status" -eq 3 ]
  [[ "$output" == *"LOSS_WARN_PCT"* ]]
  [[ "$output" == *"lib/thresholds.sh"* ]]
}

@test "netdiag --summary passes the cutoffs through" {
  # The CLI is what sources lib/thresholds.sh and exports. If it stops,
  # every metric silently loses its verdict.
  run "$REPO/bin/netdiag" --summary=1
  [ "$status" -eq 0 ]
}

@test "one recurring fault is counted once, not once per wording" {
  # The CLI interpolates its measurements into diagnosis prose, so the
  # same fault produces a different string every time it is seen. Counting
  # exact strings listed them separately — which the old 80-char
  # truncation hid and full wrapping made unmissable, one problem filling
  # sixteen lines and pushing the metrics off screen.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Losing traffic to the internet (40.0% to 8.8.8.8) though the router is clean."}]'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Losing traffic to the internet (20.0% to 8.8.8.8) though the router is clean."}]'
  run summarise_judged
  [ "$status" -eq 0 ]
  local hits
  hits="$(printf '%s\n' "$output" | grep -c 'Losing traffic to the internet')"
  [ "$hits" = "1" ] || {
    echo "expected one grouped entry, got $hits:"; echo "$output"; return 1
  }
  # And it must say it happened twice.
  [[ "$output" == *"2  Losing traffic"* ]] || { echo "$output"; return 1; }
}

@test "the newest wording is the one shown" {
  # Chronological order: the figures quoted should be from the latest
  # sighting, which is what someone acting on it now wants.
  rec "2020-01-01T00:00:00Z" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Losing traffic (11.0% to 8.8.8.8) though the router is clean."}]'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Losing traffic (99.0% to 8.8.8.8) though the router is clean."}]'
  run summarise_judged 999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"99.0%"* ]] || { echo "did not show the newest figures"; echo "$output"; return 1; }
  [[ "$output" != *"11.0%"* ]] || { echo "showed a stale wording too"; echo "$output"; return 1; }
}

@test "two genuinely different faults stay separate" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Your WiFi channel is crowded."}]'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","summary":"Your clock is drifting."}]'
  run summarise_judged
  [ "$status" -eq 0 ]
  [[ "$output" == *"WiFi channel is crowded"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"clock is drifting"* ]] || { echo "$output"; return 1; }
}

@test "a rule id groups two differently-worded sightings of one rule" {
  # When the record carries a rule id it is exactly this concept, and it
  # survives a rewording of the prose that the number-blanking fallback
  # would miss.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","rule":"L2","summary":"Old wording for this fault."}]'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    '"diagnosis":[{"severity":"warn","rule":"L2","summary":"Completely rewritten wording."}]'
  run summarise_judged
  [ "$status" -eq 0 ]
  [[ "$output" == *"2  Completely rewritten wording."* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"Old wording"* ]] || { echo "$output"; return 1; }
}
