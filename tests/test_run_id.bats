#!/usr/bin/env bats
#
# run_id: the same "<timestamp>.<8hex>" id `netdiag --history` derives for
# a stored run, computed at run time in lib/output.sh's HISTORY_APPEND
# block — by importing helpers/history.py's own canonical()/run_id()
# rather than reimplementing them — and surfaced on `--json` as `run_id`.
#
# The record appended to baseline.jsonl must never change: history.py
# derives the id from exactly those bytes, so the build that carries
# run_id can never be the build that gets stored. See lib/output.sh's
# comments at the HISTORY_APPEND block and the JSON_MODE stdout block.
#
# Two layers: network-free unit tests that call output_run() directly
# (mirroring tests/test_retention.bats), and one real round-trip through
# the CLI, which is the one thing a unit test cannot prove — that the id
# --history hands back later is the exact string --json printed at run
# time, on the same store.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS_DIR="$REPO/helpers"
  TMP="$BATS_TEST_TMPDIR"
  LOG_DIR="$TMP/net-diag"
  LOG="/dev/null"
  NETDIAG_VERSION="0.9.0"
  TARGET=""
  RUN_MODE="quick"
  TIMESTAMP_ISO="2026-01-01T00:00:00Z"
  JSON_MODE=1 QUIET=0 QUICK=1 EXPERT=0 REDACT=0 WATCH_CHILD=0
  NO_BASELINE=0 BASELINE=1 HISTORY_APPEND=1
  NETDIAG_KEEP_HISTORY=2000 NETDIAG_KEEP_LOGS=200
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/output.sh
  . "$REPO/lib/output.sh"
}

# The id history.py itself would hand back for the newest line in
# baseline.jsonl — computed with history.py's own functions, so this
# helper proves nothing on its own; it is cross-checked against the real
# CLI in the round-trip test below.
newest_stored_id() {
  python3 -c "
import json, sys
sys.path.insert(0, '$HELPERS_DIR')
from history import canonical, run_id
rec = json.loads(open('$LOG_DIR/baseline.jsonl').readlines()[-1])
print(run_id(str(rec.get('timestamp') or ''), canonical(rec)))
"
}

stdout_run_id() {
  printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])'
}

# The stored record's timings.total_s — the number the render that becomes
# baseline.jsonl carried, computed with the same $LOG_DIR the id helpers
# above already read from.
newest_stored_total_s() {
  python3 -c "
import json
rec = json.loads(open('$LOG_DIR/baseline.jsonl').readlines()[-1])
print(rec['timings']['total_s'])
"
}

stdout_total_s() {
  printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["timings"]["total_s"])'
}

# ── The append is unchanged ──────────────────────────────────────────────

@test "the appended record carries no run_id key of its own" {
  run output_run
  [ "$status" -eq 0 ]
  run python3 -c "
import json
rec = json.loads(open('$LOG_DIR/baseline.jsonl').readlines()[-1])
assert 'run_id' not in rec, rec
"
  [ "$status" -eq 0 ]
}

# ── Wiring: HISTORY_APPEND decides null vs. a real id ────────────────────

@test "run_id on stdout equals what history.py's own derivation gives the appended record" {
  run output_run
  [ "$status" -eq 0 ]
  local id
  id="$(stdout_run_id)"
  [ "$id" != "None" ]
  [ "$id" = "$(newest_stored_id)" ]
}

# run_id links a stdout render to a stored one; timings.total_s must not
# quietly disagree between the two just because each was computed at a
# different instant. See lib/output.sh's _run_elapsed_frozen.
@test "stdout's timings.total_s equals the stored record's, for the same run" {
  run output_run
  [ "$status" -eq 0 ]
  local total
  total="$(stdout_total_s)"
  [ "$total" != "None" ]
  [ "$total" = "$(newest_stored_total_s)" ]
}

@test "run_id is null when HISTORY_APPEND is off, and nothing is appended" {
  # The shape --no-baseline, --mtu-only and --wifi-only all leave records
  # in — see bin/netdiag's FOCUS block and the --no-baseline flag.
  NO_BASELINE=1 HISTORY_APPEND=0
  run output_run
  [ "$status" -eq 0 ]
  [ "$(stdout_run_id)" = "None" ]
  [ ! -e "$LOG_DIR/baseline.jsonl" ]
}

@test "run_id is null under --redact, even though the private record is still stored" {
  # build_json_private always appends the unredacted build regardless of
  # --redact (see its own header comment) — a record really is stored and
  # really does have a derivable id. run_id is nulled anyway: it is a
  # pointer back into that private copy, and the "shareable" rendition
  # should not carry a working key into data it otherwise took pains to
  # mask. See emit_json.py's redact().
  REDACT=1
  run output_run
  [ "$status" -eq 0 ]
  [ "$(stdout_run_id)" = "None" ]
  [ -e "$LOG_DIR/baseline.jsonl" ]
  [ "$(wc -l < "$LOG_DIR/baseline.jsonl")" -eq 1 ]
}

@test "two runs append two ids, and the second stdout id matches the second stored line" {
  run output_run
  [ "$status" -eq 0 ]
  TIMESTAMP_ISO="2026-01-01T00:00:05Z"
  run output_run
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG_DIR/baseline.jsonl")" -eq 2 ]
  [ "$(stdout_run_id)" = "$(newest_stored_id)" ]
}

# ── CLI round-trip (the load-bearing case: real network, real files) ─────

@test "netdiag --json's run_id matches the id netdiag --history derives for the same run" {
  local home="$TMP/home_roundtrip"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --quick --no-gping --json"
  # Not -eq 0: that means "this network is healthy", a fact about wherever
  # the test runs, not about the code under test. 3 is the one that would
  # mean netdiag itself broke.
  [ "$status" -ne 3 ]
  local run_id
  run_id="$(stdout_run_id)"
  [ "$run_id" != "None" ]
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --history"
  [ "$status" -eq 0 ]
  local hist_id
  hist_id="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runs"][-1]["id"])')"
  [ "$run_id" = "$hist_id" ]
}

@test "a stray NETDIAG_RUN_ID exported by the caller's shell never reaches the stored record" {
  # build_json sets every other NETDIAG_* var explicitly; run_id is the one
  # exception by construction (the build that becomes the stored record
  # never sets it). Without bin/netdiag's `unset NETDIAG_RUN_ID`, a var
  # already exported by the caller survives into that build's environment
  # and plants a bogus run_id key inside the very bytes history.py hashes
  # to derive the real one.
  local home="$TMP/home_stray_env"
  mkdir -p "$home"
  run bash -c "HOME='$home' NETDIAG_RUN_ID=bogus '$REPO/bin/netdiag' --quick --no-gping --json"
  [ "$status" -ne 3 ]
  local run_id
  run_id="$(stdout_run_id)"
  [ "$run_id" != "None" ]
  [ "$run_id" != "bogus" ]
  run python3 -c "
import json
rec = json.loads(open('$home/net-diag/baseline.jsonl').readlines()[-1])
assert 'run_id' not in rec, rec
"
  [ "$status" -eq 0 ]
}

@test "netdiag --redact --json's run_id is null" {
  local home="$TMP/home_redact"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --redact --quick --no-gping --json"
  [ "$status" -ne 3 ]
  [ "$(stdout_run_id)" = "None" ]
}

@test "netdiag --no-baseline --json's run_id is null" {
  local home="$TMP/home_nobaseline"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --no-baseline --quick --no-gping --json"
  [ "$status" -ne 3 ]
  [ "$(stdout_run_id)" = "None" ]
}

@test "netdiag --mtu-only --json's run_id is null, and nothing is appended" {
  local home="$TMP/home_mtu"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --mtu-only --json"
  [ "$status" -ne 3 ]
  [ "$(stdout_run_id)" = "None" ]
  [ ! -e "$home/net-diag/baseline.jsonl" ]
}

@test "netdiag --wifi-only --json's run_id is null, and nothing is appended" {
  local home="$TMP/home_wifi"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$REPO/bin/netdiag' --wifi-only --json"
  [ "$status" -ne 3 ]
  [ "$(stdout_run_id)" = "None" ]
  [ ! -e "$home/net-diag/baseline.jsonl" ]
}

