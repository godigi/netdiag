#!/usr/bin/env bats
#
# AV-1 / AV-2 — judging the event journal.
#
# These are the only rules that read evidence from outside the run that
# reports them, and the two failure modes worth guarding are both about
# honesty rather than arithmetic: counting another network's bad night
# against this one, and reporting "no outages" from a window nobody was
# watching.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  LOG_DIR="$BATS_TEST_TMPDIR"
  HELPERS_DIR="$REPO/helpers"
  J="$LOG_DIR/events.jsonl"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/availability.sh
  . "$REPO/lib/availability.sh"
  NETWORK_ID="wifi:mac=aa"
}

# Write an episode of $1 (rule) lasting $2 seconds, starting $3 minutes
# ago, on network $4 (default this one).
episode() {
  python3 - "$J" "$1" "$2" "$3" "${4:-wifi:mac=aa}" <<'PY'
import datetime, json, sys
path, rule, dur, ago, net = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
def t(delta): return (now - delta).strftime("%Y-%m-%dT%H:%M:%SZ")
start = datetime.timedelta(minutes=ago)
with open(path, "a") as f:
    f.write(json.dumps({"t": t(start), "seq": ago * 10, "network": net,
                        "network_label": "L", "kind": "rule-fired",
                        "from": None, "to": rule, "summary": "down"}) + "\n")
    f.write(json.dumps({"t": t(start - datetime.timedelta(seconds=dur)),
                        "seq": ago * 10 + 1, "network": net,
                        "network_label": "L", "kind": "rule-cleared",
                        "from": rule, "to": None, "summary": "up"}) + "\n")
PY
}

gap() {
  python3 - "$J" "$1" "$2" <<'PY'
import datetime, json, sys
path, secs, ago = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = datetime.datetime.now(datetime.timezone.utc)
stamp = (now - datetime.timedelta(minutes=ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "a") as f:
    f.write(json.dumps({"t": stamp, "seq": 1, "network": "wifi:mac=aa",
                        "network_label": "L", "kind": "gap",
                        "gap_s": secs, "summary": "g"}) + "\n")
PY
}

fire_rules() {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=0 PUBLIC_OK=1 GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
}

rules_fired() { printf ' %s ' "${DIAG_RULE[*]}"; }

# ── Reading the journal ──────────────────────────────────────────────────

@test "no journal means not measured, and no rule fires" {
  # The load-bearing one. Without a recorder there is no record, and a
  # rule that fired on that silence would be reporting "nothing was
  # watching" as "nothing went wrong".
  availability_run >/dev/null
  [ "$AV_MEASURED" -eq 0 ]
  fire_rules
  [[ "$(rules_fired)" != *" AV-1 "* ]] || { echo "AV-1 fired with no journal"; return 1; }
  [[ "$(rules_fired)" != *" AV-2 "* ]] || { echo "AV-2 fired with no journal"; return 1; }
}

@test "another network's bad night is not counted against this one" {
  # A laptop that spent yesterday on a café's broken WiFi must not have
  # that charged to the office connection it is on now.
  episode N1 600 300 "wifi:mac=THEIRS"
  episode N1 600 200 "wifi:mac=THEIRS"
  episode N1 600 100 "wifi:mac=THEIRS"
  availability_run >/dev/null
  [ "$AV_MEASURED" -eq 1 ]
  [ "$AV_OUTAGE_COUNT" -eq 0 ] || { echo "counted $AV_OUTAGE_COUNT"; return 1; }
}

@test "a bad connection is a bad connection, not a slow one" {
  # L1 (packet loss) and D1 (DNS) are a connection working badly. Counting
  # them as downtime would turn every bad afternoon into an outage.
  episode L1 600 300
  episode D1 600 200
  episode L2 600 100
  availability_run >/dev/null
  [ "$AV_OUTAGE_COUNT" -eq 0 ] || { echo "counted $AV_OUTAGE_COUNT"; return 1; }
}

@test "outages are counted, totalled, and the longest is kept" {
  episode N1 30 300
  episode P1 60 200
  episode N1c 600 100
  availability_run >/dev/null
  [ "$AV_OUTAGE_COUNT" -eq 3 ] || { echo "count=$AV_OUTAGE_COUNT"; return 1; }
  [ "$AV_DOWNTIME_S" -eq 690 ] || { echo "total=$AV_DOWNTIME_S"; return 1; }
  [ "$AV_LONGEST_S" -eq 600 ] || { echo "longest=$AV_LONGEST_S"; return 1; }
}

# ── The two rules ────────────────────────────────────────────────────────

@test "AV-1 fires on the count even when nothing was down for long" {
  # Several short drops is a flapping link; one long drop is an outage.
  # A rule needing both would report neither.
  episode N1 10 300
  episode N1 10 200
  episode N1 10 100
  availability_run >/dev/null
  [ "$AV_DOWNTIME_S" -lt "$THRESH_AV_DOWNTIME_S" ]
  fire_rules
  [[ "$(rules_fired)" == *" AV-1 "* ]] || { echo "AV-1 did not fire on count"; return 1; }
}

@test "AV-1 fires on total downtime even from a single drop" {
  episode N1 900 200
  availability_run >/dev/null
  [ "$AV_OUTAGE_COUNT" -lt "$THRESH_AV_OUTAGE_COUNT" ]
  fire_rules
  [[ "$(rules_fired)" == *" AV-1 "* ]] || { echo "AV-1 did not fire on total"; return 1; }
}

@test "one short drop is not a verdict" {
  episode N1 20 100
  availability_run >/dev/null
  fire_rules
  [[ "$(rules_fired)" != *" AV-1 "* ]] || { echo "AV-1 fired on one blip"; return 1; }
}

@test "AV-2 fires on flapping that AV-1's downtime cutoff would miss" {
  # The case no single scan can see: a check run before one of these and
  # after it finds nothing wrong both times.
  local i
  for i in 1 2 3 4 5 6 7; do episode N1 15 $(( i * 20 )); done
  availability_run >/dev/null
  [ "$AV_FLAP_COUNT" -ge "$THRESH_AV_FLAP_COUNT" ] || { echo "flaps=$AV_FLAP_COUNT"; return 1; }
  fire_rules
  [[ "$(rules_fired)" == *" AV-2 "* ]] || { echo "AV-2 did not fire"; return 1; }
}

@test "a long outage is not a flap" {
  episode N1 3600 100
  availability_run >/dev/null
  [ "$AV_FLAP_COUNT" -eq 0 ] || { echo "flaps=$AV_FLAP_COUNT"; return 1; }
}

@test "AV-1 names the evidence, not just the verdict" {
  # Acceptance criterion 8: every diagnosis explains its conclusion.
  episode N1 900 200
  availability_run >/dev/null
  fire_rules
  local i msg=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "AV-1" ] && msg="${DIAG[$i]}"
  done
  [[ "$msg" == *"15 minutes"* ]] || { echo "no duration: $msg"; return 1; }
  [[ "$msg" == *"--events"* ]] || { echo "no way to get the times: $msg"; return 1; }
}

# ── Saying when nobody was watching ──────────────────────────────────────

@test "a mostly-unobserved window says so, and still reports what was seen" {
  # Both halves matter. Silence about a real outage because the Mac also
  # slept is the worse error; claiming a clean day off six hours of
  # watching is the error the note prevents.
  episode N1 900 200
  gap 72000 100
  availability_run >/dev/null
  [ "$AV_UNOBSERVED_PCT" -ge "$THRESH_AV_UNOBSERVED_NOTE_PCT" ] \
    || { echo "unobserved=$AV_UNOBSERVED_PCT"; return 1; }
  fire_rules
  local i msg=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "AV-1" ] && msg="${DIAG[$i]}"
  done
  [[ "$msg" == *"not observed"* ]] || { echo "no observation note: $msg"; return 1; }
  [[ "$msg" == *"dropped 1 time"* ]] || { echo "outage not reported: $msg"; return 1; }
}

@test "a fully-observed window carries no caveat nobody needed" {
  episode N1 900 200
  availability_run >/dev/null
  fire_rules
  local i msg=""
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "AV-1" ] && msg="${DIAG[$i]}"
  done
  [[ "$msg" != *"not observed"* ]] || { echo "spurious note: $msg"; return 1; }
}

# ── Prose ────────────────────────────────────────────────────────────────

@test "durations read as English" {
  [ "$(availability_fmt_duration 1)" = "1 second" ]
  [ "$(availability_fmt_duration 45)" = "45 seconds" ]
  [ "$(availability_fmt_duration 60)" = "1 minute" ]
  [ "$(availability_fmt_duration 265)" = "4 minutes 25 seconds" ]
  [ "$(availability_fmt_duration 3600)" = "1 hour" ]
  [ "$(availability_fmt_duration 5400)" = "1 hour 30 minutes" ]
  [ "$(availability_fmt_duration banana)" = "an unknown time" ]
}

@test "the outage rule set lives in thresholds.sh, not in a helper" {
  # What counts as "down" decides a verdict, so it lives where every
  # other thing that decides a verdict lives.
  [ -n "$THRESH_AV_OUTAGE_RULES" ]
  run grep -c 'THRESH_AV_OUTAGE_RULES' "$REPO/lib/availability.sh"
  [ "$output" != "0" ]
  # And nowhere else keeps a second copy of it.
  run bash -c "grep -rl 'N1 N1b N1c P1 P2' '$REPO/lib' '$REPO/helpers' | grep -v thresholds.sh | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}
