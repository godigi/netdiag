#!/usr/bin/env bats
#
# lib/traffic.sh + helpers/traffic.py — what this Mac was putting on the
# link while netdiag measured the link. [TR-1]
#
# The bug this closes: a bufferbloat grade of D with a backup uploading is
# indistinguishable from a grade of D on an idle link, and netdiag blamed
# the router's queue in both cases.
#
# Everything here runs off fixtures. Staging real load is not something a
# test can do reliably — see the note on the live-sample test at the end.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/traffic.sh
  . "$REPO/lib/traffic.sh"
}

# ── The parser ───────────────────────────────────────────────────────────

@test "an idle machine's sample reports the hum, not a fault" {
  run bash -c "python3 '$REPO/helpers/traffic.py' 2 < '$FIX/nettop_idle.txt'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['measured'] is True
assert d['down_mbps'] < 1, d['down_mbps']
assert d['up_mbps'] < 1, d['up_mbps']
"
}

@test "netdiag's own probes are excluded from the totals and the talkers" {
  # The idle fixture has netdiag and curl each moving ~900 KB in the
  # window — far more than everything else in it. Counting them would
  # have netdiag reporting itself as the busiest thing on the link on
  # every single run, because the sample deliberately overlaps the
  # parallel batch.
  run bash -c "python3 '$REPO/helpers/traffic.py' 2 < '$FIX/nettop_idle.txt'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = [p['name'] for p in d['top_processes']]
assert 'netdiag' not in names, names
assert 'curl' not in names, names
# 900 KB over 2 s would be ~3.6 Mb/s; the total must be nowhere near it.
assert d['down_mbps'] < 1, d['down_mbps']
"
}

@test "a busy machine names the process and the direction" {
  run bash -c "python3 '$REPO/helpers/traffic.py' 2 < '$FIX/nettop_busy.txt'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['up_mbps'] == 44.0, d['up_mbps']
assert d['down_mbps'] == 12.16, d['down_mbps']
assert d['top_processes'][0]['name'] == 'backupd', d['top_processes']
assert d['top_processes'][0]['up_mbps'] == 40.0, d['top_processes'][0]
"
}

@test "a process that appears only in the second snapshot counts in full" {
  # It started mid-window. Its whole counter is the delta, not zero.
  printf 'time,,bytes_in,bytes_out,\n1,old.1,100,100,\ntime,,bytes_in,bytes_out,\n2,old.1,100,100,\n2,new.2,2500000,0,\n' \
    > "$BATS_TEST_TMPDIR/late.txt"
  run bash -c "python3 '$REPO/helpers/traffic.py' 1 < '$BATS_TEST_TMPDIR/late.txt'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['top_processes'][0]['name'] == 'new', d['top_processes']
assert d['down_mbps'] == 20.0, d['down_mbps']
"
}

@test "a counter that goes backwards is dropped, not clamped" {
  # A reused pid inside the window means the two numbers describe two
  # different processes, so neither difference means anything. Clamping
  # to zero would silently keep a meaningless row.
  printf 'time,,bytes_in,bytes_out,\n1,proc.1,900000,0,\ntime,,bytes_in,bytes_out,\n2,proc.1,5,0,\n' \
    > "$BATS_TEST_TMPDIR/back.txt"
  run bash -c "python3 '$REPO/helpers/traffic.py' 1 < '$BATS_TEST_TMPDIR/back.txt'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['top_processes'] == [], d['top_processes']
assert d['down_mbps'] == 0.0, d['down_mbps']
"
}

@test "one snapshot is not a measurement of zero" {
  # nettop killed early, or refusing to sample twice. 'measured': False is
  # the whole point — a zero here would qualify every number in the report
  # with a claim the run never established.
  printf 'time,,bytes_in,bytes_out,\n1,proc.1,100,100,\n' > "$BATS_TEST_TMPDIR/one.txt"
  run bash -c "python3 '$REPO/helpers/traffic.py' 2 < '$BATS_TEST_TMPDIR/one.txt'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"measured":false}' ]
}

@test "empty input is not a measurement either" {
  run bash -c ": | python3 '$REPO/helpers/traffic.py' 2"
  [ "$status" -eq 0 ]
  [ "$output" = '{"measured":false}' ]
}

@test "the helper rejects a non-numeric window rather than dividing by it" {
  run bash -c "python3 '$REPO/helpers/traffic.py' banana < '$FIX/nettop_busy.txt'"
  [ "$status" -eq 3 ]
}

# ── The floor ────────────────────────────────────────────────────────────

@test "traffic_at_least is false when nothing was measured" {
  TRAFFIC_MEASURED=0 TRAFFIC_DOWN_MBPS=999 TRAFFIC_UP_MBPS=999
  run traffic_at_least "$THRESH_TRAFFIC_BUSY_MBPS"
  [ "$status" -ne 0 ]
}

@test "traffic_at_least compares floats, which [ -gt ] cannot" {
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=12.16 TRAFFIC_UP_MBPS=0.01
  run traffic_at_least "$THRESH_TRAFFIC_BUSY_MBPS"
  [ "$status" -eq 0 ]
}

@test "either direction alone is enough to count as busy" {
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=0.01 TRAFFIC_UP_MBPS=44
  run traffic_at_least "$THRESH_TRAFFIC_BUSY_MBPS"
  [ "$status" -eq 0 ]
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=0.05 TRAFFIC_UP_MBPS=0.02
  run traffic_at_least "$THRESH_TRAFFIC_BUSY_MBPS"
  [ "$status" -ne 0 ]
}

@test "the busier direction is the one named" {
  TRAFFIC_DOWN_MBPS=2 TRAFFIC_UP_MBPS=44
  [ "$(traffic_busier_direction)" = "44 Mb/s up" ]
  TRAFFIC_DOWN_MBPS=90 TRAFFIC_UP_MBPS=1
  [ "$(traffic_busier_direction)" = "90 Mb/s down" ]
}

# ── The rule ─────────────────────────────────────────────────────────────

@test "TR-1 is info on its own and warn beside a verdict it undermines" {
  # The escalation is the whole design: traffic is a fact, not a fault,
  # until it becomes a competing explanation for a finding the user is
  # about to act on.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"

  GATEWAY=192.168.1.1 IS_WIFI=0 PUBLIC_OK=1 GW_LOSS=0
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=0.2 TRAFFIC_UP_MBPS=44 TRAFFIC_TOP_NAME=backupd
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local i sev=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "TR-1" ] && sev="${DIAG_SEV[$i]}"
  done
  [ "$sev" = info ] || { echo "expected info alone, got '$sev'"; return 1; }

  # Now with a bufferbloat verdict already recorded.
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  add_diag warn B1 "pretend bufferbloat finding"
  diagnosis_run >/dev/null
  sev=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "TR-1" ] && sev="${DIAG_SEV[$i]}"
  done
  [ "$sev" = warn ] || { echo "expected warn beside B1, got '$sev'"; return 1; }
}

@test "TR-1 stays quiet below the floor" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=0 PUBLIC_OK=1 GW_LOSS=0
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=0.05 TRAFFIC_UP_MBPS=0.02 TRAFFIC_TOP_NAME=mDNSResponder
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" != *" TR-1 "* ]] || { echo "TR-1 fired on an idle link"; return 1; }
}

@test "TR-1 names the busiest process in its sentence" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=0 PUBLIC_OK=1 GW_LOSS=0
  TRAFFIC_MEASURED=1 TRAFFIC_DOWN_MBPS=0.2 TRAFFIC_UP_MBPS=44 TRAFFIC_TOP_NAME=backupd
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local i msg=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "TR-1" ] && msg="${DIAG[$i]}"
  done
  [[ "$msg" == *backupd* ]] || { echo "no process named: $msg"; return 1; }
  [[ "$msg" == *"44 Mb/s up"* ]] || { echo "no rate named: $msg"; return 1; }
}

# ── The live path, as far as a test can honestly go ──────────────────────

@test "nettop on this machine produces two differenceable snapshots" {
  # Deliberately not an assertion about magnitude. Staging real load from
  # a test is unreliable — a background transfer may finish before the
  # window, and in a sandboxed runner it may not be attributed to this
  # machine's interface at all — so this asserts only the part that can
  # be established: nettop exists, runs unprivileged, and yields two
  # snapshots the parser can difference. The numbers are covered by the
  # fixtures above.
  command -v nettop >/dev/null || skip "nettop not available"
  run bash -c "nettop -P -x -J bytes_in,bytes_out -L 2 -s 1 2>/dev/null | python3 '$REPO/helpers/traffic.py' 1"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['measured'] is True, d
assert isinstance(d['down_mbps'], float)
assert isinstance(d['top_processes'], list)
"
}
