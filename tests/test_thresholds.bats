#!/usr/bin/env bats
#
# lib/thresholds.sh is the single source of truth for every number a
# diagnosis fires on. Three consumers now read it — lib/diagnosis.sh (one
# verdict per scan), lib/monitor.sh (one verdict every few seconds) and
# helpers/history.py (one verdict per stored run, in --show) — and the
# failure mode this file guards is them drifting apart: a menu-bar dot that
# says "unstable" over a report that says "healthy" discredits both, and
# the user has no way to tell which lied.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
}

# ── The file stands alone ────────────────────────────────────────────────

@test "thresholds.sh sources standalone under set -eu with nothing else loaded" {
  # lib/monitor.sh sources it on its own. If it ever grows a dependency on
  # common.sh or globals.sh, the monitor breaks at spawn time rather than
  # at review time.
  run bash -c "set -eu; . '$REPO/lib/thresholds.sh'; printf '%s' \"\$LOSS_CRIT_PCT\""
  [ "$status" -eq 0 ]
  [ "$output" = "20" ]
}

@test "every threshold a rule reads is defined" {
  for v in LOSS_WARN_PCT LOSS_CRIT_PCT LOSS_PROBE_COUNT LOSS_PROBE_INTERVAL \
           THRESH_GW_LOSS_CRIT_PCT THRESH_ICMP_FILTERED_LOSS_PCT \
           THRESH_ICMP_TOTAL_LOSS_PCT THRESH_WIFI_RSSI_WEAK_DBM \
           THRESH_WIFI_RSSI_G1_DBM THRESH_WIFI_SNR_LOW_DB \
           THRESH_WIFI_CHANNEL_NEIGHBOURS THRESH_WIFI_DISCONNECTS \
           THRESH_WIFI_RSSI_EXCELLENT_DBM THRESH_LATENCY_JITTER_WARN_MS \
           THRESH_IPV6_LOSS_PCT THRESH_MTU_STANDARD THRESH_MTU_CRIT \
           THRESH_MTU_FULL_PATH THRESH_MTU_ETHERNET \
           THRESH_GATEWAY_QUICK_PING_COUNT \
           THRESH_NTP_DRIFT_CRIT_S THRESH_NTP_DRIFT_WARN_S \
           THRESH_DHCP_LEASE_WARN_S THRESH_BUFFERBLOAT_A_MS \
           THRESH_BUFFERBLOAT_B_MS THRESH_BUFFERBLOAT_C_MS \
           THRESH_BUFFERBLOAT_D_MS THRESH_COMPARE_MIN_SAMPLES \
           THRESH_COMPARE_TAIL_PCTL THRESH_MON_LOSS_CONFIRM_CYCLES \
           THRESH_SPEED_DROP_FACTOR THRESH_SPEED_CONFIRM_RUNS \
           THRESH_BASELINE_GW_RTT_FLOOR_MS \
           THRESH_MTR_HOP_LOSS_PCT THRESH_WIFI_GOODPUT_CEILING_PCT \
           THRESH_WIFI_EVENTS_STORED THRESH_MON_GAP_FACTOR \
           THRESH_WATCHER_INTERVAL_S THRESH_WATCHER_STALE_FACTOR \
           THRESH_AV_WINDOW_HOURS THRESH_AV_OUTAGE_RULES \
           THRESH_AV_OUTAGE_COUNT THRESH_AV_DOWNTIME_S \
           THRESH_AV_FLAP_MAX_S THRESH_AV_FLAP_COUNT \
           THRESH_AV_UNOBSERVED_NOTE_PCT; do
    [ -n "${!v:-}" ] || { echo "undefined threshold: $v"; return 1; }
  done
}

@test "no diagnosis rule carries an inline numeric cutoff" {
  # The regression this catches: someone tightening a rule by editing the
  # literal in diagnosis.sh, leaving monitor.sh on the old value. Matches
  # the comparison operators against a bare number, so prose that happens
  # to contain a digit is not a hit.
  #
  # Zero is excluded deliberately: `-gt 0` on DHCP_TIME_REMAINING_S asks
  # "did we measure anything?", not "is it past a cutoff". Sentinels of
  # that shape are validity guards and belong inline; no policy threshold
  # in this project is 0.
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$REPO/lib/diagnosis.sh"
  [ "$status" -ne 0 ] || { echo "inline cutoff in diagnosis.sh:"; echo "$output"; return 1; }
}

@test "helpers/history.py carries no inline numeric cutoff either" {
  # --show judges a stored run against its network's history, so this file
  # is now the third thing in the project that decides whether a number is
  # normal. It reads THRESH_COMPARE_* from the environment; the regression
  # this catches is a cutoff creeping back in as a Python literal, where
  # nothing in lib/thresholds.sh would ever reflect a change to it.
  #
  # Same shape as the bash guard: a comparison operator against a bare
  # number. Zero is excluded for the same reason — `if n > 0` asks "did we
  # measure anything?", not "is this past a cutoff" — and a comparison
  # against a named constant is exactly what this test wants to see.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/history.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in history.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in history.py" {
  # A grep-based guard is only as good as its pattern, and a pattern that
  # matches nothing passes for the wrong reason. Plant one and prove it.
  cp "$REPO/helpers/history.py" "$BATS_TEST_TMPDIR/planted.py"
  printf '\nif False:\n    pass  # if percentile >= 90:\n' >> "$BATS_TEST_TMPDIR/planted.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted.py"
  [ "$status" -eq 0 ]
}

@test "helpers/history.py refuses to judge without the thresholds" {
  # A default in the Python would be a second home for a number that has
  # exactly one, and a stale second copy still produces a plausible
  # verdict — the failure nobody notices.
  printf '{"timestamp":"2026-01-01T00:00:00Z","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}}\n' \
    > "$BATS_TEST_TMPDIR/baseline.jsonl"
  run env -u THRESH_COMPARE_MIN_SAMPLES -u THRESH_COMPARE_TAIL_PCTL \
    python3 "$REPO/helpers/history.py" --history "$BATS_TEST_TMPDIR/baseline.jsonl" \
    --show 2026-01-01T00:00:00Z
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_COMPARE_MIN_SAMPLES"* ]] || return 1
  [[ "$output" == *"lib/thresholds.sh"* ]] || return 1
}

@test "the comparison tail leaves a middle band" {
  # At 50 or above the two tails meet and every value is simultaneously
  # notable at both ends, so which verdict a run gets would come down to
  # the order the branches happen to be written in.
  [ "$THRESH_COMPARE_TAIL_PCTL" -lt 50 ]
}

# ── The two RSSI cutoffs really are different ────────────────────────────
# W1's -75 and G1's -70 sit four lines apart in diagnosis.sh and mean
# different things: -75 is "your signal is bad enough to complain about",
# -70 is "your signal is bad enough to explain the packets going missing".
# Collapsing them would change which fix the user is told to try.

@test "at 25% gateway loss, G2 fires as critical while G3 stays quiet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=25 PUBLIC_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" == *" G2 "* ]] || return 1
  [[ "$rules" != *" G3 "* ]] || return 1
}

@test "at 10% gateway loss, G3 fires as warn while G2 stays quiet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=10 PUBLIC_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" == *" G3 "* ]] || return 1
  [[ "$rules" != *" G2 "* ]] || return 1
}

@test "raising a threshold in one place changes the rule that reads it" {
  # Proves the refactor is live wiring and not a parallel set of constants
  # sitting unused next to the original literals.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 PUBLIC_OK=1 GW_LOSS=25
  THRESH_GW_LOSS_CRIT_PCT=90
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" != *" G2 "* ]] || return 1
  [[ "$rules" == *" G3 "* ]] || return 1
}

@test "weak WiFi signal emits W1 even without gateway loss" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-76 WIFI_SNR=30
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" W1 "* ]] || return 1
}

@test "low WiFi SNR emits W2" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 WIFI_SNR=19
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" W2 "* ]] || return 1
}

@test "a crowded WiFi channel emits WS-1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 WIFI_SNR=30
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=4 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" WS-1 "* ]] || return 1
}

# ── grade_bufferbloat reads the same table ───────────────────────────────

@test "grade_bufferbloat maps the Waveform bands from the shared constants" {
  [ "$(grade_bufferbloat 1)"   = A ]
  [ "$(grade_bufferbloat 20)"  = B ]
  [ "$(grade_bufferbloat 45)"  = C ]
  [ "$(grade_bufferbloat 150)" = D ]
  [ "$(grade_bufferbloat 500)" = F ]
}

@test "grade_bufferbloat boundaries are exclusive at the lower edge" {
  [ "$(grade_bufferbloat "$THRESH_BUFFERBLOAT_A_MS")" = B ]
  [ "$(grade_bufferbloat "$THRESH_BUFFERBLOAT_D_MS")" = F ]
}

@test "helpers/judgement.py carries no inline numeric cutoff either" {
  # judgement.py is the shared pair-table both history.py's judged block
  # and summary.py's judged rows now read, so a cutoff creeping back in
  # here as a Python literal is the single worst place for it: it would
  # silently retune both consumers at once. Same guard, same reasoning as
  # the history.py and summary.py checks above.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/judgement.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in judgement.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in judgement.py" {
  cp "$REPO/helpers/judgement.py" "$BATS_TEST_TMPDIR/planted_judgement.py"
  printf '\nif False:\n    pass  # if value >= 20:\n' >> "$BATS_TEST_TMPDIR/planted_judgement.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_judgement.py"
  [ "$status" -eq 0 ]
}

@test "helpers/history.py refuses to build judged verdicts without the judging thresholds" {
  # Distinct from "helpers/history.py refuses to judge without the
  # thresholds" above: that test covers THRESH_COMPARE_* (--show's
  # comparison); this one covers the six JUDGED_METRICS cutoffs the plain
  # --history listing's judged block now reads in every mode, main()
  # requires them unconditionally so this is not scoped to --show.
  printf '{"timestamp":"2026-01-01T00:00:00Z","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}}\n' \
    > "$BATS_TEST_TMPDIR/baseline.jsonl"
  run env THRESH_COMPARE_MIN_SAMPLES="$THRESH_COMPARE_MIN_SAMPLES" \
          THRESH_COMPARE_TAIL_PCTL="$THRESH_COMPARE_TAIL_PCTL" \
      python3 "$REPO/helpers/history.py" --history "$BATS_TEST_TMPDIR/baseline.jsonl"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LOSS_WARN_PCT"* ]] || return 1
  [[ "$output" == *"lib/thresholds.sh"* ]] || return 1
}

@test "helpers/summary.py carries no inline numeric cutoff either" {
  # --summary now judges each metric line, so this file is the fourth
  # thing in the project that decides whether a number is normal. Same
  # guard as the history.py one above, same reasoning: a cutoff creeping
  # back as a Python literal is a number lib/thresholds.sh would never
  # reflect a change to.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/summary.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in summary.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in summary.py" {
  cp "$REPO/helpers/summary.py" "$BATS_TEST_TMPDIR/planted_summary.py"
  printf '\nif False:\n    pass  # if loss >= 20:\n' >> "$BATS_TEST_TMPDIR/planted_summary.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_summary.py"
  [ "$status" -eq 0 ]
}
