#!/usr/bin/env bats
#
# `netdiag --show=<id>` — one stored run, and what "normal" means for the
# network it was taken on. Two things can go silently wrong here and both
# are covered below.
#
# The first is addressing: a run is named by an id, and an id that resolves
# to the wrong record shows the user a report for a check they did not ask
# for, with nothing in the output to give it away. Two runs land in the
# same second often enough for that to be a real case, not a hypothetical.
#
# The second is arithmetic. Every verdict here is a comparison against a
# distribution, so the fixtures are ramps — twenty runs, 1…20 — whose
# median, tails and percentile ranks can be worked out by hand and read
# back off the page.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  TMP="$BATS_TEST_TMPDIR"
  LIVE="$TMP/baseline.jsonl"
  ARCHIVE="$TMP/baseline-archive.jsonl"
  : > "$LIVE"
  # Sourced rather than hardcoded, so a test can never pass against a
  # cutoff production does not use. bin/netdiag exports exactly these.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export THRESH_COMPARE_MIN_SAMPLES THRESH_COMPARE_TAIL_PCTL
}

NET='"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'

# rec <file> <ts> <json-body…> — append one record, as in test_history.bats.
rec() {
  local file="$1" ts="$2"; shift 2
  printf '{"version":"0.6.0","timestamp":"%s"%s}\n' "$ts" "${1:+,$1}" >> "$file"
}

# ramp <json-body> — twenty runs on one network, one per day, with every @
# in the body replaced by the day number: metrics read 1.0 through 20.0.
# Median 10.5; with a 10-point tail, p10 is 2.9 and p90 is 18.1
# (interpolated between order statistics).
ramp() {
  local body="$1" i
  for i in $(seq 1 20); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" "$NET,${body//@/$i}"
  done
}

hist() {
  python3 "$HELPERS/history.py" --history "$LIVE" "$@"
}

show() {
  python3 "$HELPERS/history.py" --history "$LIVE" --show "$1"
}

# Pull one value out of an emitted object with a dotted/indexed path.
get() {
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split('.'):
    d = d[int(k)] if k.lstrip('-').isdigit() else d.get(k)
    if d is None: break
print(json.dumps(d, ensure_ascii=False, sort_keys=True))
" "$1"
}

sget() {
  local id="$1" path="$2"
  show "$id" | get "$path"
}

# The metric block for one key of one run, so a verdict test reads as one
# line rather than three.
verdict() {
  sget "$1" "comparison.metrics.$2.verdict"
}

ids() {
  hist | python3 -c \
    'import json,sys
for r in json.load(sys.stdin)["runs"]:
    print(r["id"])'
}

# Put the fixture where bin/netdiag looks for it.
as_home() {
  mkdir -p "$TMP/net-diag"
  cp "$LIVE" "$TMP/net-diag/baseline.jsonl"
  [ -e "$ARCHIVE" ] && cp "$ARCHIVE" "$TMP/net-diag/baseline-archive.jsonl"
  return 0
}

# ── Run ids ──────────────────────────────────────────────────────────────
# `ts` alone cannot address a run: the store already dedups on the record's
# bytes as well, precisely because two runs share a second.

@test "every --history run carries an id of timestamp.hex" {
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET"
  run hist
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,re,sys
run = json.load(sys.stdin)['runs'][0]
assert re.fullmatch(r'2026-01-01T00:00:00Z\.[0-9a-f]{8}', run['id']), run['id']
assert run['ts'] == '2026-01-01T00:00:00Z', run['ts']
"
}

@test "an id is stable across invocations" {
  # It is a handle the app stores and comes back with. If it moved between
  # two runs of the CLI, every cached detail would open the wrong report.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.4}"
  local first second
  first="$(ids)"
  second="$(ids)"
  [ "$first" = "$second" ]
}

@test "two runs in the same second get different ids" {
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.1}"
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":9.7}"
  run ids
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "byte-identical duplicates collapse to one id, as they collapse to one run" {
  # The archive/live overlap prune_history can leave behind. The id hashes
  # the same bytes dedup keys on, so the two can never disagree about
  # whether these are one run or two.
  rec "$ARCHIVE" 2026-01-01T00:00:00Z "$NET"
  rec "$LIVE"    2026-01-01T00:00:00Z "$NET"
  run ids
  [ "${#lines[@]}" -eq 1 ]
}

@test "the id separator is a dot, not a '#' zsh would glob" {
  # Under zsh with EXTENDED_GLOB — on by default in many setups — an
  # unquoted --show=…#… is a pattern and fails with "no matches found".
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET"
  run ids
  [[ "$output" != *"#"* ]]
  [[ "$output" == *"."* ]]
}

# ── Addressing one run ───────────────────────────────────────────────────

@test "an id from --history round-trips through --show" {
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.4}"
  rec "$LIVE" 2026-01-02T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":4.1}"
  local id
  id="$(ids | tail -1)"
  run sget "$id" id
  [ "$output" = "\"$id\"" ]
  run sget "$id" run.timestamp
  [ "$output" = '"2026-01-02T00:00:00Z"' ]
}

@test "each of two runs in the same second resolves to its own record" {
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.1}"
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":9.7}"
  local first second
  first="$(ids | head -1)"
  second="$(ids | tail -1)"
  run sget "$first" run.gateway.rtt_avg_ms
  [ "$output" = "3.1" ]
  run sget "$second" run.gateway.rtt_avg_ms
  [ "$output" = "9.7" ]
}

@test "a bare timestamp resolves when it names exactly one run" {
  # What a person actually has in front of them, from a log filename or a
  # report header.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.4}"
  run sget 2026-01-01T00:00:00Z run.gateway.rtt_avg_ms
  [ "$output" = "3.4" ]
}

@test "an ambiguous timestamp exits 3 and lists the candidates" {
  # Picking one would show a report for a run nobody asked for.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.1}"
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":9.7}"
  local first second
  first="$(ids | head -1)"
  second="$(ids | tail -1)"
  run show 2026-01-01T00:00:00Z
  [ "$status" -eq 3 ]
  [[ "$output" == *"$first"* ]]
  [[ "$output" == *"$second"* ]]
}

@test "an unknown id exits 3" {
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET"
  run show 2026-01-01T00:00:00Z.deadbeef
  [ "$status" -eq 3 ]
}

@test "a run that lives only in the archive is still reachable" {
  # The archive is part of the store. A detail view that could not open a
  # rolled-over run would break the moment retention first fires.
  rec "$ARCHIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":7.7}"
  rec "$LIVE"    2026-06-01T00:00:00Z "$NET"
  run sget 2026-01-01T00:00:00Z run.gateway.rtt_avg_ms
  [ "$output" = "7.7" ]
}

@test "the stored record comes back exactly as it was written" {
  # The app decodes `run` with the same model it uses for a live scan, so
  # anything added, dropped or renamed here breaks a two-month-old record.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"dhcp\":{\"dns_servers\":\"1.1.1.1 8.8.8.8\"},\"diagnosis\":[{\"severity\":\"warn\",\"rule\":\"M1\",\"summary\":\"path MTU is 1400\"}]"
  run show 2026-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
stored = json.loads(open(sys.argv[1]).readline())
assert d['run'] == stored, d['run']
assert 'id' not in d['run'], 'the id is metadata about the record, not part of it'
" "$LIVE"
}

# ── Context ──────────────────────────────────────────────────────────────

@test "context places the run in its network's history, oldest first" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run sget 2026-01-05T00:00:00Z context.position
  [ "$output" = "5" ]
  run sget 2026-01-05T00:00:00Z context.runs_on_network
  [ "$output" = "20" ]
  run sget 2026-01-05T00:00:00Z context.first_seen
  [ "$output" = '"2026-01-01T00:00:00Z"' ]
  run sget 2026-01-05T00:00:00Z context.last_seen
  [ "$output" = '"2026-01-20T00:00:00Z"' ]
}

@test "context.network_id is the grouped key --history reports" {
  # Not the raw network.id: grouping is what reconciles four eras of
  # netdiag's identity scheme, and the app joins the detail to the network
  # card on this string.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET"
  run sget 2026-01-01T00:00:00Z context.network_id
  [ "$output" = '"mac:aa:bb:cc:dd:ee:ff"' ]
}

@test "runs_on_network counts every run; a metric's n counts the ones that measured it" {
  # 1,915 checks and 38 bufferbloat readings is the normal shape of this
  # store, and the gap is the point — a chart that hides it presents two
  # readings as a trend.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  rec "$LIVE" 2026-01-21T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":5.0},\"bufferbloat\":{\"gw_delta_ms\":12.0}"
  run sget 2026-01-21T00:00:00Z context.runs_on_network
  [ "$output" = "21" ]
  run sget 2026-01-21T00:00:00Z comparison.metrics.gateway_rtt_ms.n
  [ "$output" = "21" ]
  run sget 2026-01-21T00:00:00Z comparison.metrics.bufferbloat_gw_ms.n
  [ "$output" = "1" ]
}

@test "runs on another network are not in the population" {
  # The whole reason a comparison is scoped: a laptop's home median has
  # nothing to say about a hotel's.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  rec "$LIVE" 2026-02-01T00:00:00Z '"network":{"id":"wifi:mac=11:22:33:44:55:66"},"gateway":{"rtt_avg_ms":900.0}'
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.n
  [ "$output" = "20" ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.median
  [ "$output" = "10.5" ]
}

# ── Comparison arithmetic ────────────────────────────────────────────────
# The tail is pinned in these tests so the expected numbers describe the
# arithmetic rather than today's cutoff. That the cutoff is wired at all is
# the "a wider tail moves the verdict" test below.

@test "median, p10 and p90 come off the raw distribution" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.median
  [ "$output" = "10.5" ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.p10
  [ "$output" = "2.9" ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.p90
  [ "$output" = "18.1" ]
}

@test "percentile is the raw ascending rank, with no direction applied" {
  # 3.0 is the third smallest of twenty, so it ranks low whether low is
  # good or bad. Only the verdict knows the difference.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run sget 2026-01-03T00:00:00Z comparison.metrics.gateway_rtt_ms.percentile
  [ "$output" = "12" ]
  run sget 2026-01-18T00:00:00Z comparison.metrics.gateway_rtt_ms.percentile
  [ "$output" = "88" ]
}

@test "ties are averaged, so a network that is always perfect stays typical" {
  # 0.0% loss in every run: counting ties as "at or below" would put every
  # one of them at the 100th percentile and call a flawless run the worst
  # thing that ever happened here.
  ramp '"gateway":{"rtt_avg_ms":@.0,"loss_pct":0.0}'
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_loss_pct.percentile
  [ "$output" = "50" ]
  run verdict 2026-01-05T00:00:00Z gateway_loss_pct
  [ "$output" = '"typical"' ]
}

@test "the value being compared is the one this run recorded" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run sget 2026-01-07T00:00:00Z comparison.metrics.gateway_rtt_ms.value
  [ "$output" = "7.0" ]
}

# ── Verdicts ─────────────────────────────────────────────────────────────

@test "a run in the middle of the distribution is typical" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run verdict 2026-01-10T00:00:00Z gateway_rtt_ms
  [ "$output" = '"typical"' ]
}

@test "a low latency in the lower tail is better, and the lowest is best" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run verdict 2026-01-02T00:00:00Z gateway_rtt_ms
  [ "$output" = '"better"' ]
  run verdict 2026-01-01T00:00:00Z gateway_rtt_ms
  [ "$output" = '"best"' ]
}

@test "a high latency in the upper tail is worse, and the highest is worst" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run verdict 2026-01-19T00:00:00Z gateway_rtt_ms
  [ "$output" = '"worse"' ]
  run verdict 2026-01-20T00:00:00Z gateway_rtt_ms
  [ "$output" = '"worst"' ]
}

@test "direction inverts the tails: the fastest download is best, the slowest worst" {
  # The reason there is one symmetric tail cutoff and not a "better" and a
  # "worse" percentile: for throughput the *low* percentile is the bad end.
  ramp '"speedtest":{"down_mbps":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run sget 2026-01-20T00:00:00Z comparison.metrics.speed_down_mbps.percentile
  [ "$output" = "98" ]
  run verdict 2026-01-20T00:00:00Z speed_down_mbps
  [ "$output" = '"best"' ]
  run verdict 2026-01-19T00:00:00Z speed_down_mbps
  [ "$output" = '"better"' ]
  run verdict 2026-01-02T00:00:00Z speed_down_mbps
  [ "$output" = '"worse"' ]
  run verdict 2026-01-01T00:00:00Z speed_down_mbps
  [ "$output" = '"worst"' ]
}

@test "the same upper tail is 'worse' for latency and 'better' for throughput" {
  ramp '"gateway":{"rtt_avg_ms":@.0},"speedtest":{"down_mbps":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run verdict 2026-01-19T00:00:00Z gateway_rtt_ms
  [ "$output" = '"worse"' ]
  run verdict 2026-01-19T00:00:00Z speed_down_mbps
  [ "$output" = '"better"' ]
}

@test "a wider tail moves the verdict — the cutoff is live wiring" {
  # Proves THRESH_COMPARE_TAIL_PCTL reaches the arithmetic, rather than
  # sitting in thresholds.sh next to a Python literal that does the work.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  THRESH_COMPARE_TAIL_PCTL=10
  run verdict 2026-01-03T00:00:00Z gateway_rtt_ms
  [ "$output" = '"typical"' ]
  THRESH_COMPARE_TAIL_PCTL=20
  run verdict 2026-01-03T00:00:00Z gateway_rtt_ms
  [ "$output" = '"better"' ]
}

@test "too few samples is insufficient_data, not a confident verdict" {
  local i
  for i in $(seq 1 $((THRESH_COMPARE_MIN_SAMPLES - 1))); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" \
      "$NET,\"gateway\":{\"rtt_avg_ms\":$i.0}"
  done
  run verdict 2026-01-01T00:00:00Z gateway_rtt_ms
  [ "$output" = '"insufficient_data"' ]
  # The percentile is withheld with it: over a handful of readings it
  # states a precision the sample does not have.
  run sget 2026-01-01T00:00:00Z comparison.metrics.gateway_rtt_ms.percentile
  [ "$output" = "null" ]
  # …but the value the run recorded is still reported.
  run sget 2026-01-01T00:00:00Z comparison.metrics.gateway_rtt_ms.value
  [ "$output" = "1.0" ]
}

@test "one more sample crosses into a real verdict" {
  local i
  for i in $(seq 1 "$THRESH_COMPARE_MIN_SAMPLES"); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" \
      "$NET,\"gateway\":{\"rtt_avg_ms\":$i.0}"
  done
  run verdict 2026-01-05T00:00:00Z gateway_rtt_ms
  [ "$output" != '"insufficient_data"' ]
}

@test "a metric this run never measured is not_measured, and never a zero" {
  # The distinction the whole schema is built on. A bufferbloat probe that
  # did not run is not a bufferbloat delta of 0 ms.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run verdict 2026-01-05T00:00:00Z bufferbloat_gw_ms
  [ "$output" = '"not_measured"' ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.bufferbloat_gw_ms.value
  [ "$output" = "null" ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.bufferbloat_gw_ms.n
  [ "$output" = "0" ]
}

@test "a measured zero is a measurement, not a gap" {
  ramp '"gateway":{"rtt_avg_ms":@.0,"loss_pct":0.0}'
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_loss_pct.value
  [ "$output" = "0.0" ]
  run verdict 2026-01-05T00:00:00Z gateway_loss_pct
  [ "$output" != '"not_measured"' ]
}

@test "not_measured still reports what the network usually does" {
  # The run has no reading; the network does. Saying so is the difference
  # between "unknown" and "we have nothing".
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  rec "$LIVE" 2026-01-21T00:00:00Z "$NET,\"wifi\":{\"rssi\":-55}"
  run verdict 2026-01-21T00:00:00Z gateway_rtt_ms
  [ "$output" = '"not_measured"' ]
  run sget 2026-01-21T00:00:00Z comparison.metrics.gateway_rtt_ms.median
  [ "$output" = "10.5" ]
  run sget 2026-01-21T00:00:00Z comparison.metrics.gateway_rtt_ms.summary
  [[ "$output" == *"Not measured in this check"* ]]
  [[ "$output" == *"10.5 ms"* ]]
}

@test "every verdict in the closed set is reachable" {
  # docs/JSON-SCHEMA.md lists seven and the UI styles each one. A verdict
  # string that no code path emits is a UI state nobody will ever see; one
  # this test does not know about is a UI state nobody styled.
  ramp '"gateway":{"rtt_avg_ms":@.0},"speedtest":{"down_mbps":@.0}'
  rec "$LIVE" 2026-01-21T00:00:00Z "$NET,\"wifi\":{\"rssi\":-55}"
  THRESH_COMPARE_TAIL_PCTL=10
  local seen=""
  seen="$seen $(verdict 2026-01-01T00:00:00Z gateway_rtt_ms)"     # best
  seen="$seen $(verdict 2026-01-02T00:00:00Z gateway_rtt_ms)"     # better
  seen="$seen $(verdict 2026-01-10T00:00:00Z gateway_rtt_ms)"     # typical
  seen="$seen $(verdict 2026-01-19T00:00:00Z gateway_rtt_ms)"     # worse
  seen="$seen $(verdict 2026-01-20T00:00:00Z gateway_rtt_ms)"     # worst
  seen="$seen $(verdict 2026-01-05T00:00:00Z bufferbloat_gw_ms)"  # not_measured
  seen="$seen $(verdict 2026-01-21T00:00:00Z wifi_rssi_dbm)"      # insufficient_data
  local v
  for v in best better typical worse worst not_measured insufficient_data; do
    [[ "$seen" == *"\"$v\""* ]] || { echo "unreachable verdict: $v ($seen)"; return 1; }
  done
}

# ── Shape ────────────────────────────────────────────────────────────────

@test "the comparison block is always present, even with nothing to compare" {
  # An absent block would make the app render "no comparison" and "too few
  # checks" as the same thing; only one of them is informative.
  rec "$LIVE" 2026-01-01T00:00:00Z "$NET,\"gateway\":{\"rtt_avg_ms\":3.4}"
  run show 2026-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for k in ('schema','version','id','run','context','comparison'):
    assert k in d, k
m = d['comparison']['metrics']['gateway_rtt_ms']
assert m['verdict'] == 'insufficient_data', m
assert set(m) == {'value','median','p10','p90','percentile','n',
                  'direction','verdict','summary'}, sorted(m)
"
}

@test "the metrics compared are exactly the ones --history charts" {
  # One table, not two: METRICS already states a direction per metric,
  # which is why the CLI and not the GUI knows whether higher is better.
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run bash -c "
    diff <(python3 '$HELPERS/history.py' --history '$LIVE' \
             | python3 -c 'import json,sys; [print(m[\"key\"]) for m in json.load(sys.stdin)[\"metrics\"]]') \
         <(python3 '$HELPERS/history.py' --history '$LIVE' --show 2026-01-05T00:00:00Z \
             | python3 -c 'import json,sys; [print(k) for k in json.load(sys.stdin)[\"comparison\"][\"metrics\"]]')
  "
  [ "$status" -eq 0 ]
}

@test "direction is carried through per metric" {
  ramp '"gateway":{"rtt_avg_ms":@.0},"speedtest":{"down_mbps":@.0}'
  run sget 2026-01-05T00:00:00Z comparison.metrics.gateway_rtt_ms.direction
  [ "$output" = '"lower_is_better"' ]
  run sget 2026-01-05T00:00:00Z comparison.metrics.speed_down_mbps.direction
  [ "$output" = '"higher_is_better"' ]
}

@test "the summary reads as a sentence the app can print unchanged" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run sget 2026-01-10T00:00:00Z comparison.metrics.gateway_rtt_ms.summary
  [ "$output" = '"10 ms — typical for this network (median 10.5 ms across 20 checks)."' ]
}

# ── CLI surface ──────────────────────────────────────────────────────────

@test "netdiag --show=ID emits one parseable object and exits 0" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  as_home
  local id
  id="$(ids | head -1)"
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show='$id'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "netdiag --show ID accepts the space-separated form too" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  as_home
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show 2026-01-05T00:00:00Z"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"position":5'* ]]
}

@test "netdiag --show with no id exits 3, not 2" {
  # 2 is reserved for a real diagnosis, so a wrapper can tell a typo from a
  # broken network.
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show"
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a run id"* ]]
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show="
  [ "$status" -eq 3 ]
}

@test "netdiag --show with an unknown id exits 3, not 2" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  as_home
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show=2026-01-05T00:00:00Z.deadbeef"
  [ "$status" -eq 3 ]
}

@test "netdiag --show stamps the running version, not the record's" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  as_home
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --show=2026-01-05T00:00:00Z \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"version\"], d[\"run\"][\"version\"])'"
  [ "$status" -eq 0 ]
  [ "${output% *}" != "0.6.0" ]
  [ "${output#* }" = "0.6.0" ]
}

@test "--show is documented in --help" {
  run "$REPO/bin/netdiag" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--show"* ]]
}
