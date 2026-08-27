#!/usr/bin/env bats
#
# helpers/speedtest_result.py — the parser that replaced ~10 `jq -r` calls
# in lib/speedtest.sh, so netdiag's speed test no longer needs jq on PATH.
#
# Network-free by construction: every test drives the helper directly
# against a fixture or an inline JSON string on stdin, the same style
# tests/test_monitor.bats uses for its pure functions. Nothing here runs
# an actual speed test.
#
# The privacy test is the load-bearing one. An Ookla result object carries
# interface.internalIp — on a dual-stack Mac, the host's public IPv6
# address — plus externalIp, macAddr and a result.url that all identify
# the household or the run. lib/speedtest.sh documents this as a security
# boundary; this file is where the boundary is actually tested, the same
# way tests/test_progress.bats tests it for speedtest_translate_line's
# testStart handling.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  FIXTURES="$REPO/tests/fixtures"
  LIB="$REPO/lib"
}

parse() {
  python3 "$HELPERS/speedtest_result.py"
}

# Splits bats' $output (set by a prior `run`) into the five tab-separated
# fields, via the same tab -> `|` fix as production — see
# _speedtest_parse_result in lib/speedtest.sh, and the "real shell
# function" section below, which tests that fix directly.
split_output() {
  local line="${output//$'\t'/|}"
  IFS='|' read -r down up lat jit server <<<"$line"
}

# ── Ookla flavor: math and field paths ───────────────────────────────────

@test "ookla: bandwidth math is exact (60875000 bytes/s -> 487.0 Mbps)" {
  run parse < "$FIXTURES/ookla-result.jsonl"
  [ "$status" -eq 0 ]
  split_output
  [ "$down" = "487.0" ]
  [ "$up" = "91.0" ]
}

@test "ookla: latency and jitter are passed through, not recomputed" {
  run parse < "$FIXTURES/ookla-result.jsonl"
  [ "$status" -eq 0 ]
  split_output
  [ "$lat" = "13.755" ]
  [ "$jit" = "0.418" ]
}

@test "ookla: server name comes from server.name" {
  run parse < "$FIXTURES/ookla-result.jsonl"
  [ "$status" -eq 0 ]
  split_output
  [ "$server" = "Example Speedtest Host" ]
}

# ── speedtest-cli flavor: bits/s already, different field paths ─────────

@test "cli: bandwidth is already bits/s, only the scale changes" {
  run parse < "$FIXTURES/speedtestcli-result.json"
  [ "$status" -eq 0 ]
  split_output
  [ "$down" = "93.4" ]
  [ "$up" = "11.2" ]
}

@test "cli: ping is a bare number, not nested under ping.latency" {
  run parse < "$FIXTURES/speedtestcli-result.json"
  [ "$status" -eq 0 ]
  split_output
  [ "$lat" = "18.432" ]
}

@test "cli: has no jitter field, so that column is empty" {
  run parse < "$FIXTURES/speedtestcli-result.json"
  [ "$status" -eq 0 ]
  split_output
  [ -z "$jit" ]
}

@test "cli: server comes from server.host, not server.name" {
  run parse < "$FIXTURES/speedtestcli-result.json"
  [ "$status" -eq 0 ]
  split_output
  # server.name ("Springfield") is present in the fixture too — this
  # would pass for the wrong reason if the helper preferred it.
  [ "$server" = "speedtest.example.invalid:8080" ]
  [ "$server" != "Springfield" ]
}

# ── Absent fields, malformed input ───────────────────────────────────────

@test "absent fields produce empty columns, not an error" {
  run parse <<<'{"download":{"bandwidth":12345000},"server":{}}'
  [ "$status" -eq 0 ]
  split_output
  [ "$down" = "98.8" ]
  [ -z "$up" ]
  [ -z "$lat" ]
  [ -z "$jit" ]
  [ -z "$server" ]
}

@test "malformed JSON on stdin: five empty columns, exit 0" {
  run parse <<<'this is not json'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '\t\t\t\t')" ]
}

@test "empty stdin: five empty columns, exit 0" {
  run parse < /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '\t\t\t\t')" ]
}

@test "a JSON value that isn't an object: five empty columns, exit 0" {
  run parse <<<'[1,2,3]'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '\t\t\t\t')" ]
}

@test "download present but the wrong type: five empty columns" {
  # Neither an Ookla-shaped object nor a speedtest-cli-shaped number —
  # deny-by-default means an unrecognized shape is treated the same as
  # absent, never guessed at.
  run parse <<<'{"download":"fast","upload":"slow"}'
  [ "$status" -eq 0 ]
  split_output
  [ -z "$down" ]
  [ -z "$up" ]
}

@test "a boolean in a numeric field is rejected, not read as 1" {
  run parse <<<'{"download":{"bandwidth":true}}'
  [ "$status" -eq 0 ]
  split_output
  [ -z "$down" ]
}

# ── Privacy: identifying fields never reach stdout ───────────────────────

@test "privacy: interface IPs, MAC and result.url never appear in output" {
  run parse < "$FIXTURES/ookla-result.jsonl"
  [ "$status" -eq 0 ]
  for secret in \
    "2001:db8::dead:beef" \
    "203.0.113.7" \
    "CA:54:39:8F:E5:9A" \
    "speedtest.net/result" \
    "01234567-89ab-cdef-0123-456789abcdef"
  do
    [[ "$output" != *"$secret"* ]] || {
      echo "leaked: $secret"
      return 1
    }
  done
}

@test "privacy: only the five documented fields appear, nothing else" {
  # Positive control on the negative test above: what SHOULD be in the
  # output is exactly the five extracted values, so a secret leaking in
  # via a sixth field would be caught even if it happened not to collide
  # with the probe strings above.
  run parse < "$FIXTURES/ookla-result.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '487.0\t91.0\t13.755\t0.418\tExample Speedtest Host')" ]
}

# ── lib/speedtest.sh no longer requires jq ───────────────────────────────
#
# Structural, not behavioral: actually removing jq from PATH and re-running
# a check belongs to the CI "no jq on PATH" smoke test (a real process, a
# real PATH), which is the only way to prove the *run* survives. This is
# the cheap, deterministic half — a source grep that fails the instant
# either function regains a `command -v jq` / `jq -e` / `jq -r` gate,
# regardless of whether jq happens to be installed on whatever machine
# runs the suite.

# The body of one function, by name, out of lib/speedtest.sh — from its
# header line up to (not including) the next top-level function/closing
# brace at column 0.
_speedtest_sh_function_body() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { found=1 }
    found { print }
    found && /^}/ { exit }
  ' "$LIB/speedtest.sh"
}

@test "speedtest_will_run no longer mentions jq" {
  body="$(_speedtest_sh_function_body speedtest_will_run)"
  [ -n "$body" ]
  # A bare `*jq*` grep is brittle — an innocent comment mentioning jq
  # would flip this red. Match the specific gates instead, same as the
  # speedtest_run test below.
  [[ "$body" != *"command -v jq"* ]] || return 1
  [[ "$body" != *"jq -e"* ]] || return 1
  [[ "$body" != *"jq -r"* ]] || return 1
}

@test "speedtest_run's own body has no jq gate left (parsing moved to the helper)" {
  body="$(_speedtest_sh_function_body speedtest_run)"
  [ -n "$body" ]
  [[ "$body" != *"command -v jq"* ]] || return 1
  [[ "$body" != *"jq -e"* ]] || return 1
  [[ "$body" != *"jq -r"* ]] || return 1
}

# ── _speedtest_parse_result(): the real shell function ───────────────────
#
# Everything above drives helpers/speedtest_result.py directly. Nothing
# yet has run the bash function that actually wraps it in production —
# the tab -> `|` translation, the empty-input early return, and the
# return-1 contract are all unexercised by the tests above, which means a
# "simplification" back to a naive `IFS=$'\t' read` would pass every test
# in this file while breaking every speedtest-cli result it parses. Source
# the real lib/speedtest.sh inside each @test, the same pattern
# tests/test_progress.bats uses for speedtest_translate_line, and set
# HELPERS_DIR first since _speedtest_parse_result shells out to the
# helper by that path.

@test "_speedtest_parse_result: speedtest-cli fixture — down/up/latency correct, jitter empty, server correct" {
  HELPERS_DIR="$HELPERS"
  # shellcheck source=../lib/speedtest.sh
  . "$LIB/speedtest.sh"
  local raw rc
  raw="$(cat "$FIXTURES/speedtestcli-result.json")"
  _speedtest_parse_result "$raw"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$SPEEDTEST_DOWN_MBPS" = "93.4" ]
  [ "$SPEEDTEST_UP_MBPS" = "11.2" ]
  [ "$SPEEDTEST_LATENCY_MS" = "18.432" ]
  # The exact field the tab-collapse bug corrupts: a naive
  # `IFS=$'\t' read` treats this empty column and the tab after it as one
  # delimiter, shifting the server name into SPEEDTEST_JITTER_MS and
  # leaving SPEEDTEST_SERVER empty.
  [ -z "$SPEEDTEST_JITTER_MS" ]
  [ "$SPEEDTEST_SERVER" = "speedtest.example.invalid:8080" ]
}

@test "_speedtest_parse_result: ookla fixture — all five fields land" {
  HELPERS_DIR="$HELPERS"
  # shellcheck source=../lib/speedtest.sh
  . "$LIB/speedtest.sh"
  local raw rc
  raw="$(cat "$FIXTURES/ookla-result.jsonl")"
  _speedtest_parse_result "$raw"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$SPEEDTEST_DOWN_MBPS" = "487.0" ]
  [ "$SPEEDTEST_UP_MBPS" = "91.0" ]
  [ "$SPEEDTEST_LATENCY_MS" = "13.755" ]
  [ "$SPEEDTEST_JITTER_MS" = "0.418" ]
  [ "$SPEEDTEST_SERVER" = "Example Speedtest Host" ]
}

@test "_speedtest_parse_result: empty input returns 1, globals stay empty" {
  HELPERS_DIR="$HELPERS"
  # shellcheck source=../lib/speedtest.sh
  . "$LIB/speedtest.sh"
  local rc=0
  _speedtest_parse_result "" || rc=$?
  [ "$rc" -eq 1 ]
  [ -z "$SPEEDTEST_DOWN_MBPS" ]
  [ -z "$SPEEDTEST_UP_MBPS" ]
  [ -z "$SPEEDTEST_LATENCY_MS" ]
  [ -z "$SPEEDTEST_JITTER_MS" ]
  [ -z "$SPEEDTEST_SERVER" ]
}

# ── The metered-link guard [MET-1] ───────────────────────────────────────
#
# The one skip in speedtest_run that is about the user's money rather than
# about time. The speed test moves hundreds of megabytes, and on a phone's
# hotspot that comes out of a cellular allowance — spent by a tool the
# user ran to ask a question, without being asked.

speed_guard_setup() {
  JSON_MODE=0 QUIET=0 QUICK=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$LIB/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$LIB/common.sh"
  # shellcheck source=../lib/speedtest.sh
  . "$LIB/speedtest.sh"
  SPEED=1 NO_SPEED=0 PUBLIC_OK=1 SPEED_EXPLICIT=0
  LINK_METERED=0 LINK_SERVICE=""
  # EXPERT=1 so `info` actually reaches stdout here. In a default run
  # _should_print_stdout suppresses it before the diagnosis section, and
  # that is deliberate: the user learns *why* the speed test is missing
  # from MET-1 in the Diagnosis section, not from a log line. Same
  # principle as "a captive portal is a diagnosis in a scan, not a log
  # line" (ee20ac0). This test asserts the notice exists and says the
  # right thing; MET-1's own tests assert the user-facing half.
  EXPERT=1 DIAGNOSIS_REACHED=0
  # A marker file rather than stdout: speedtest_flavor's output is
  # captured into a variable by speedtest_run, so anything echoed here
  # would be invisible to the assertions.
  REACHED="$BATS_TEST_TMPDIR/reached"
  rm -f "$REACHED"
  speedtest_flavor() { : > "$REACHED"; printf 'none:none'; }
}

@test "speedtest: a metered link skips the test by default" {
  speed_guard_setup
  LINK_METERED=1 LINK_SERVICE="iPhone USB"
  run speedtest_run
  [ "$status" -eq 0 ]
  case "$output" in
    *"metered connection"*) ;;
    *) echo "no metered notice in: $output"; return 1 ;;
  esac
  [ ! -e "$REACHED" ] || { echo "the guard fell through to the real test"; return 1; }
  # The skip must say how to override it, or it is just a missing result.
  case "$output" in
    *"--speed"*) ;;
    *) echo "skip notice does not mention --speed: $output"; return 1 ;;
  esac
}

@test "speedtest: an explicit --speed overrides the metered skip" {
  # The user keeps the choice. This is a default, not a prohibition.
  speed_guard_setup
  LINK_METERED=1 LINK_SERVICE="iPhone USB" SPEED_EXPLICIT=1
  speedtest_run >/dev/null 2>&1
  [ -e "$REACHED" ] || { echo "--speed did not override the guard"; return 1; }
}

@test "speedtest: an unmetered link is unaffected" {
  speed_guard_setup
  LINK_METERED=0
  speedtest_run >/dev/null 2>&1
  [ -e "$REACHED" ] || { echo "the guard fired on an unmetered link"; return 1; }
}

@test "speedtest: the metered notice names the service" {
  speed_guard_setup
  LINK_METERED=1 LINK_SERVICE="iPhone USB"
  run speedtest_run
  case "$output" in
    *"iPhone USB"*) ;;
    *) echo "service not named: $output"; return 1 ;;
  esac
}
