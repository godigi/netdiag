#!/usr/bin/env bats
#
# The --progress event stream on fd 3, and the run_mode that says how much
# of the battery a record actually represents.
#
# Two failure modes are guarded here and neither is visible at runtime:
#
#   1. The plan drifts from the run sequence. The plan is a declared list,
#      and a declared list goes stale the first time a check is added — a
#      phase missing from it shows up in the UI as an event nobody asked
#      for, and a phase only in it hangs forever as "still running". Same
#      guard shape as tests/test_thresholds.bats uses for cutoffs.
#
#   2. A field of Ookla's stream that nobody meant to forward reaches fd 3.
#      Its testStart line carries interface.internalIp, which on a
#      dual-stack Mac is the machine's public IPv6 address. The translation
#      is deny-by-default for that reason and this file plants the value to
#      prove it.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
}

# Every phase name bin/netdiag hands to a wrapper, deduped and sorted.
wrapper_names() {
  # [a-z0-9_] and not [a-z_]: `ipv6` has a digit in it, and a pattern
  # that quietly skips one phase is a guard that passes while the thing it
  # guards is broken.
  grep -oE '^ *(run_timed|launch_parallel) +[a-z0-9_]+' "$NETDIAG" \
    | awk '{print $2}' | sort -u
}

# Every phase name any mode declares, deduped and sorted.
declared_names() {
  local mode
  for mode in full quick mtu-only wifi-only speed-only; do
    progress_plan_phases "$mode"
  done | sort -u
}

# ── The plan and the run sequence agree ──────────────────────────────────

@test "every phase bin/netdiag runs is declared in some mode's plan" {
  local missing
  missing="$(comm -23 <(wrapper_names) <(declared_names))"
  [ -z "$missing" ] || {
    echo "run_timed/launch_parallel names absent from every plan:"
    echo "$missing"
    echo "add them to progress_plan_phases in lib/common.sh"
    return 1
  }
}

@test "every phase a plan declares is one bin/netdiag actually runs" {
  local extra
  extra="$(comm -13 <(wrapper_names) <(declared_names))"
  [ -z "$extra" ] || {
    echo "planned phases that nothing in bin/netdiag runs:"
    echo "$extra"
    return 1
  }
}

@test "the guard would actually catch a phase added to only one side" {
  # A comm-based guard is only as good as its extraction, and an extraction
  # that matches nothing passes for the wrong reason. Plant one and prove it.
  cp "$NETDIAG" "$BATS_TEST_TMPDIR/planted"
  printf '\nrun_timed brand_new brand_new_run\n' >> "$BATS_TEST_TMPDIR/planted"
  NETDIAG="$BATS_TEST_TMPDIR/planted"
  run wrapper_names
  [[ "$output" == *"brand_new"* ]]
  local missing
  missing="$(comm -23 <(wrapper_names) <(declared_names))"
  [ "$missing" = "brand_new" ]
}

@test "each focused mode plans only the phases it needs" {
  # --mtu-only must not promise a speed test, and --speed-only must not
  # promise a traceroute. An over-broad plan is the version of this bug the
  # symmetry tests above cannot see: both sides stay consistent while the
  # UI lists phases that will never report.
  run progress_plan_phases mtu-only
  [[ "$output" != *speedtest* ]]
  [[ "$output" == *mtu* ]]
  run progress_plan_phases speed-only
  [[ "$output" != *traceroute* ]]
  [[ "$output" == *speedtest* ]]
  run progress_plan_phases wifi-only
  [[ "$output" != *public* ]]
  [[ "$output" == *wifi_scan* ]]
}

@test "a plan event stays well under PIPE_BUF" {
  # Parallel subshells share fd 3 and a pipe write is atomic only to
  # PIPE_BUF (512 bytes on macOS). The plan is the longest event there is,
  # so if anything crosses the line it is this.
  PROGRESS=1
  local line
  line="$(progress_plan full 3>&1 >/dev/null)"
  [ "${#line}" -lt 512 ] || { echo "plan event is ${#line} bytes"; return 1; }
}

# ── The emitter ──────────────────────────────────────────────────────────

@test "nothing reaches fd 3 with progress off" {
  PROGRESS=0
  local out
  out="$( { progress_plan full; progress_phase_start x; progress_phase_done x 0 5;
            progress_phase_skip x why; progress_speed download 0.5 10.0 3.0;
            progress_run_done 0; } 3>&1 >/dev/null )"
  [ -z "$out" ]
}

@test "every event is one line of parseable JSON" {
  PROGRESS=1
  local out
  out="$( { progress_plan full; progress_phase_start gateway
            progress_phase_done gateway 0 2043
            progress_phase_skip wifi_scan "not on wifi"
            progress_speed download 0.42 180.3 ""
            progress_run_done 1; } 3>&1 >/dev/null )"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 6 ]
  printf '%s\n' "$out" | python3 -c '
import json, sys
for line in sys.stdin:
    json.loads(line)
'
}

@test "the event shapes match the ones docs/JSON-SCHEMA.md documents" {
  PROGRESS=1
  local out
  out="$(progress_phase_done gateway 0 2043 3>&1 >/dev/null)"
  [ "$out" = '{"t":"phase","name":"gateway","state":"done","rc":0,"ms":2043}' ]
  out="$(progress_phase_skip wifi_scan "not on wifi" 3>&1 >/dev/null)"
  [ "$out" = '{"t":"phase","name":"wifi_scan","state":"skip","why":"not on wifi"}' ]
  out="$(progress_run_done 1 3>&1 >/dev/null)"
  [ "$out" = '{"t":"run","state":"done","exit":1}' ]
}

@test "an unmeasured speed field is null, never zero" {
  # The distinction the whole schema turns on: a test that has not reached
  # the download stage has no throughput, which is not 0 Mbps.
  PROGRESS=1
  local out
  out="$(progress_speed ping 0.4 "" 28.9 3>&1 >/dev/null)"
  [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mbps"])')" = "None" ]
  [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ms"])')" = "28.9" ]
}

@test "a skip reason with quotes and newlines stays one parseable line" {
  PROGRESS=1
  local out
  out="$(progress_phase_skip mtr "$(printf 'he said "no"\nand a \\ too')" 3>&1 >/dev/null)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["why"])')" \
    = 'he said "no" and a \ too' ]
}

@test "a long skip reason is clamped without breaking its JSON" {
  # Clamping after escaping would cut between a backslash and the character
  # it escapes. Feed it a reason that is nothing but backslashes.
  PROGRESS=1
  local out
  out="$(progress_phase_skip mtr "$(printf '\\%.0s' $(seq 1 400))" 3>&1 >/dev/null)"
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
  [ "${#out}" -lt 512 ]
}

# ── run_timed / launch_parallel emit for every check ─────────────────────

@test "run_timed brackets a check with start and done" {
  PROGRESS=1
  noop() { return 0; }
  local out
  out="$(run_timed thing noop 3>&1 >/dev/null)"
  [[ "$(printf '%s\n' "$out" | head -1)" == '{"t":"phase","name":"thing","state":"start"}' ]]
  [[ "$(printf '%s\n' "$out" | tail -1)" == *'"state":"done","rc":0'* ]]
}

@test "run_timed reports the check's own exit status in rc" {
  PROGRESS=1
  failer() { return 7; }
  local out
  # `|| true` because bats runs under set -e and the point of the test is a
  # check that failed.
  out="$(run_timed thing failer 3>&1 >/dev/null || true)"
  [[ "$out" == *'"rc":7'* ]]
}

@test "a check that calls progress_skip emits skip and never done" {
  PROGRESS=1
  skipper() { progress_skip "--quick"; return 0; }
  local out
  out="$(run_timed bufferbloat skipper 3>&1 >/dev/null)"
  [[ "$out" == *'"state":"skip","why":"--quick"'* ]]
  [[ "$out" != *'"state":"done"'* ]]
}

@test "a skip does not leak into the next phase" {
  # NETDIAG_PHASE_SKIP is one variable reused by every phase, so a stale
  # value would report the *next* check as skipped with the previous
  # check's reason — plausible enough that nobody would question it.
  PROGRESS=1
  skipper() { progress_skip "--quick"; }
  worker()  { return 0; }
  local out
  out="$( { run_timed bufferbloat skipper; run_timed mtu worker; } 3>&1 >/dev/null )"
  [[ "$out" == *'{"t":"phase","name":"mtu","state":"done"'* ]]
}

@test "run_timed still records its timing row and preserves exit status" {
  # The progress hook was added to a function whose job is timing. Neither
  # of its original two contracts may have moved.
  PROGRESS=0
  TIMING_LINES=""
  failer() { return 3; }
  local rc=0
  run_timed phaseA failer || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$TIMING_LINES" == "phaseA|"* ]]
}

@test "a parallel check announces itself from inside its own subshell" {
  # The reason the stream is on fd 3 at all: launch_parallel redirects the
  # subshell's stdout AND stderr into a per-check buffer, so an event on
  # either would be invisible until collect_parallel replayed it.
  PROGRESS=1
  parallel_thing() { say "buffered"; return 0; }
  local out
  out="$( { launch_parallel pthing parallel_thing; collect_parallel; } 3>&1 >/dev/null )"
  [[ "$out" == *'{"t":"phase","name":"pthing","state":"start"}'* ]]
  [[ "$out" == *'"name":"pthing","state":"done","rc":0'* ]]
  [[ "$out" != *buffered* ]]
}

@test "parallel events are never interleaved mid-line" {
  # Every subshell shares one fd. Each event is a single short printf so
  # the write stays atomic; assembling one from two writes would let two
  # checks finishing together produce a line that parses as neither.
  PROGRESS=1
  quick_thing() { return 0; }
  local out i
  out="$( { for i in 1 2 3 4 5 6 7 8; do
              launch_parallel "check_$i" quick_thing
            done
            collect_parallel; } 3>&1 >/dev/null )"
  printf '%s\n' "$out" | python3 -c '
import json, sys
n = 0
for line in sys.stdin:
    json.loads(line)
    n += 1
assert n == 16, f"expected 16 events, got {n}"
'
}

# ── Ookla translation: deny-by-default ───────────────────────────────────

@test "the Ookla translation forwards no field but the four named ones" {
  # The fixture is a real testStart line with the addresses replaced. If
  # any of them can reach fd 3, so can the user's actual IPv6 address.
  PROGRESS=1
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  local out
  out="$(speedtest_translate_line "$(cat "$REPO/tests/fixtures/ookla-teststart.jsonl")" 3>&1 >/dev/null)"
  for secret in 2001:db8 203.0.113 CA:54:39 speedtest.example.invalid "Example Telecom"; do
    [[ "$out" != *"$secret"* ]] || { echo "leaked $secret in: $out"; return 1; }
  done
  [ "$out" = '{"t":"speed","stage":"testStart","progress":null,"mbps":null,"ms":null}' ]
}

@test "a hostile field name cannot smuggle a value through the number match" {
  # The numeric extraction matches "key":<number> and nothing else, so a
  # string can never satisfy it however it is named.
  PROGRESS=1
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  local out
  out="$(speedtest_translate_line \
    '{"type":"ping","internalIp":"2001:db8::1","progress":"2001:db8::1","ping":{"latency":"2001:db8::2","progress":0.4}}' \
    3>&1 >/dev/null)"
  [[ "$out" != *2001:db8* ]]
  [ "$out" = '{"t":"speed","stage":"ping","progress":0.4,"mbps":null,"ms":null}' ]
}

@test "the Ookla translation reads progress, bandwidth and latency where they live" {
  PROGRESS=1
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  local out
  # progress is nested under the type-named object, not top level.
  out="$(speedtest_translate_line \
    '{"type":"download","timestamp":"x","download":{"bandwidth":1343097,"bytes":12288,"elapsed":9,"progress":0.001}}' \
    3>&1 >/dev/null)"
  [ "$out" = '{"t":"speed","stage":"download","progress":0.001,"mbps":10.7,"ms":null}' ]
  out="$(speedtest_translate_line \
    '{"type":"ping","timestamp":"x","ping":{"jitter":0.000,"latency":27.942,"progress":0.200}}' \
    3>&1 >/dev/null)"
  # Forwarded verbatim, 0.200 and not 0.2: the value is Ookla's, and
  # renormalising it would mean parsing it, which is what this must not do.
  [ "$out" = '{"t":"speed","stage":"ping","progress":0.200,"mbps":null,"ms":27.942}' ]
}

@test "a result line's latency object does not masquerade as a latency reading" {
  # download.latency is an object on the result line and ping.latency is a
  # number. Matching the object would emit "ms":{ and stop being JSON.
  PROGRESS=1
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  local out
  out="$(speedtest_translate_line \
    '{"type":"result","ping":{"jitter":25.6,"latency":29.437},"download":{"bandwidth":6142773,"latency":{"iqm":46.199}}}' \
    3>&1 >/dev/null)"
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
  [ "$out" = '{"t":"speed","stage":"result","progress":null,"mbps":49.1,"ms":29.437}' ]
}

@test "a line that is not JSON at all produces no event" {
  PROGRESS=1
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  local out
  out="$(speedtest_translate_line 'Speedtest by Ookla' 3>&1 >/dev/null)"
  [ -z "$out" ]
}

# ── The CLI surface ──────────────────────────────────────────────────────

@test "--progress and --speed-only are documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--progress"* ]]
  [[ "$output" == *"--speed-only"* ]]
}

@test "--speed-only with --no-speed is a usage error, and exits 3 not 2" {
  run "$NETDIAG" --speed-only --no-speed
  [ "$status" -eq 3 ]
  [[ "$output" == *"conflict"* ]]
}

@test "--json --progress still puts exactly one object on stdout" {
  # Acceptance criterion 2 is the reason the stream is not on stdout.
  run bash -c "'$NETDIAG' --quick --json --progress --no-baseline --log /dev/null 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d[\"run_mode\"])
'"
  [ "$status" -eq 0 ]
  [ "$output" = "quick" ]
}

@test "--progress off leaves stderr empty on a non-tty" {
  run bash -c "'$NETDIAG' --quick --json --no-baseline --log /dev/null 2>&1 >/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
