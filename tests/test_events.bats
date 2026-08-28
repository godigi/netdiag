#!/usr/bin/env bats
#
# The event journal — netdiag remembering what happened.
#
# The gap this closes, from docs/design/nothing-was-watching.md: netdiag
# could always say what was wrong *now* and never what was wrong at 03:14
# or for how long. The monitor observed every transition, rendered it, used
# it to decide whether to notify, and then discarded it. `--monitor
# --journal` writes those transitions down; `--events` reads them back.
#
# What is asserted here is pairing and honesty about observation. Nothing
# judges a duration: whether four minutes of downtime is acceptable is a
# verdict, and verdicts live in lib/diagnosis.sh against lib/thresholds.sh.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  EVENTS="$REPO/helpers/events.py"
  J="$BATS_TEST_TMPDIR/events.jsonl"
}

# One journal line. $1 kind, $2 timestamp, $3 seq, then kind-specific args.
ev() {
  local kind="$1" ts="$2" seq="$3"; shift 3
  local extra=""
  case "$kind" in
    rule-fired)   extra=",\"from\":null,\"to\":\"$1\"" ;;
    rule-cleared) extra=",\"from\":\"$1\",\"to\":null" ;;
    gap)          extra=",\"gap_s\":$1" ;;
  esac
  local net="${NET:-wifi:mac=aa}"
  printf '{"t":"%s","seq":%s,"network":"%s","network_label":"Home","kind":"%s","summary":"s"%s}\n' \
    "$ts" "$seq" "$net" "$kind" "$extra" >> "$J"
}

read_events() {
  python3 "$EVENTS" --journal "$J" --version test
}

# ── Pairing ──────────────────────────────────────────────────────────────

@test "a fault that fired and cleared becomes an episode with a duration" {
  # The whole point: "the internet was down from 03:14 for 4m25s" is a
  # sentence netdiag could not previously produce at all.
  ev monitor-started 2026-08-28T01:00:00Z 1
  ev rule-fired      2026-08-28T03:14:00Z 900 N1
  ev rule-cleared    2026-08-28T03:18:25Z 930 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = [e for e in d['episodes'] if e['rule'] == 'N1']
assert len(eps) == 1, d['episodes']
assert eps[0]['duration_s'] == 265, eps[0]
assert eps[0]['ongoing'] is False, eps[0]
assert eps[0]['ended_by'] == 'cleared', eps[0]
"
}

@test "the same fault on two networks is two episodes" {
  # Keyed on (network, rule). Otherwise a laptop that moves has one
  # network's recovery closing the other network's fault.
  NET=wifi:mac=aa ev rule-fired 2026-08-28T01:00:00Z 1 G3
  NET=wifi:mac=bb ev rule-fired 2026-08-28T01:01:00Z 2 G3
  NET=wifi:mac=aa ev rule-cleared 2026-08-28T01:05:00Z 3 G3
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = {(e['network'], e['ongoing']): e for e in d['episodes']}
assert len(d['episodes']) == 2, d['episodes']
assert eps[('wifi:mac=aa', False)]['duration_s'] == 300
assert ('wifi:mac=bb', True) in eps, list(eps)
"
}

@test "an episode still open at the end is measured to the last event, not to now" {
  # Reporting 'ongoing for 4 hours' when the recorder stopped an hour ago
  # invents observation that never happened. The duration must stop where
  # the record stops.
  ev rule-fired 2020-01-01T00:00:00Z 1 N1
  ev gap        2020-01-01T00:10:00Z 2 60
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ep = d['episodes'][0]
assert ep['ongoing'] is True, ep
assert ep['ended_by'] == 'still-open', ep
# 10 minutes to the last event, not the years since 2020.
assert ep['duration_s'] == 600, ep
"
}

@test "a monitor restart closes an open episode as a lower bound" {
  # The recorder died or the Mac rebooted. Whatever happened to that fault
  # in between was not observed, so the episode must not silently span it.
  ev rule-fired      2026-08-28T03:00:00Z 900 N1
  ev monitor-started 2026-08-28T03:05:00Z 1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ep = d['episodes'][0]
assert ep['ended_by'] == 'monitor-restart', ep
assert ep['duration_is_lower_bound'] is True, ep
assert ep['duration_s'] == 300, ep
"
}

@test "a fault re-observed after a restart keeps its earliest known start" {
  # Firing twice with no clear between means the recorder restarted and
  # saw the same fault again. The earliest sighting is the earliest moment
  # it is known to have been true.
  ev rule-fired 2026-08-28T03:00:00Z 900 G3
  ev rule-fired 2026-08-28T03:02:00Z 901 G3
  ev rule-cleared 2026-08-28T03:10:00Z 902 G3
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d['episodes']) == 1, d['episodes']
assert d['episodes'][0]['duration_s'] == 600, d['episodes'][0]
"
}

@test "a clear with no matching fire is not an episode" {
  # The recorder started mid-fault and only saw the recovery. Inventing a
  # start time for it would be inventing a duration.
  ev rule-cleared 2026-08-28T03:00:00Z 1 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['episodes'] == []
"
}

# ── Honesty about what was observed ──────────────────────────────────────

@test "a gap inside an episode is recorded, not absorbed into its duration" {
  # A four-hour outage and a four-hour closed lid produce the same silence.
  # The difference has to survive into the answer.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  ev gap        2026-08-28T02:00:00Z 2 28800
  ev rule-cleared 2026-08-28T03:00:00Z 3 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
ep = json.load(sys.stdin)['episodes'][0]
assert ep['duration_s'] == 7200, ep
assert ep['unobserved_s'] == 28800, ep
"
}

@test "the window reports the fraction of itself nobody was watching" {
  ev monitor-started 2026-08-28T00:00:00Z 1
  ev gap             2026-08-28T04:00:00Z 2 3600
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
o = json.load(sys.stdin)['observation']
assert o['gap_count'] == 1, o
assert o['unobserved_s'] == 3600, o
assert o['monitor_starts'] == 1, o
assert o['unobserved_fraction'] is not None, o
"
}

# ── The file itself ──────────────────────────────────────────────────────

@test "a truncated final line costs one event, not the whole answer" {
  # The recorder killed mid-write. Reading must degrade, not fail.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  printf '{"t":"2026-08-28T01:01:00Z","seq":2,"kin' >> "$J"
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['counts']['events'] == 1, d['counts']
"
}

@test "duplicate lines from an interrupted archive roll are deduped" {
  # _journal_prune appends to the archive before truncating the live file,
  # so a crash between the two duplicates lines rather than dropping them.
  # That is only the safe failure because this dedupes.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  cp "$J" "$BATS_TEST_TMPDIR/events-archive.jsonl"
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['counts']['events'] == 1
"
}

@test "an absent journal is an empty answer, not an error" {
  run python3 "$EVENTS" --journal "$BATS_TEST_TMPDIR/nope.jsonl" --version test
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['episodes'] == [] and d['counts']['events'] == 0
"
}

# ── The CLI surface ──────────────────────────────────────────────────────

@test "--events emits one parseable JSON object" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --events=24"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
}

@test "--events with a non-numeric window is a usage error, not a diagnosis" {
  # Exit 3, never 2: 2 is reserved for a real finding so wrappers can tell
  # a broken invocation from a broken network.
  run "$NETDIAG" --events=banana
  [ "$status" -eq 3 ]
}

@test "--monitor without --journal still writes nothing to disk" {
  # The documented contract of --monitor, and the reason --journal is
  # opt-in: a consumer piping this stream into its own program gets a
  # process that touches no disk.
  home="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$NETDIAG' --monitor --monitor-fast-interval 1 --monitor-count 2 >/dev/null 2>&1"
  [ ! -e "$home/net-diag/events.jsonl" ]
}

@test "--monitor --journal writes the file it was given" {
  home="$BATS_TEST_TMPDIR/j"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$NETDIAG' --monitor --journal '$home/ev.jsonl' --monitor-fast-interval 1 --monitor-count 2 >/dev/null 2>&1"
  [ -s "$home/ev.jsonl" ]
  # Always at least the start marker, so a reader can tell "nothing
  # happened" from "nothing was running".
  run grep -c 'monitor-started' "$home/ev.jsonl"
  [ "$output" = "1" ]
}

@test "--journal pointing somewhere unwritable fails at startup, not silently" {
  # Dropping every event for days because a path was wrong is the failure
  # ND-1 exists to catch one level up. Fail loudly, immediately.
  run "$NETDIAG" --monitor --journal /nope/nowhere/ev.jsonl --monitor-count 1
  [ "$status" -eq 3 ]
  [[ "$output" == *journal* ]] || { echo "$output"; return 1; }
}

@test "events and recorder are advertised in --capabilities" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
f = json.load(sys.stdin)['features']
assert 'events' in f, f
assert 'recorder' in f, f
"
}

@test "--install-recorder refuses a TCC-protected path, like the watcher" {
  fake_home="$BATS_TEST_TMPDIR/rhome"
  mkdir -p "$fake_home/Documents/netdiag/bin" "$fake_home/Library/LaunchAgents"
  cp "$NETDIAG" "$fake_home/Documents/netdiag/bin/netdiag"
  cp -R "$REPO/lib" "$REPO/helpers" "$fake_home/Documents/netdiag/"
  run env HOME="$fake_home" "$fake_home/Documents/netdiag/bin/netdiag" --install-recorder
  [ "$status" -eq 3 ]
  [ ! -f "$fake_home/Library/LaunchAgents/com.netdiag.recorder.plist" ]
}

@test "the recorder and the watcher are separate agents" {
  # They answer different questions — a snapshot every fifteen minutes
  # versus every transition — and neither replaces the other.
  run bash -c "grep -c 'com.netdiag.recorder' '$REPO/lib/watchdog.sh'"
  [ "$output" != "0" ]
  run bash -c "grep -q 'RECORDER_LABEL=\"com.netdiag.recorder\"' '$REPO/lib/watchdog.sh'"
  [ "$status" -eq 0 ]
}
