#!/usr/bin/env bats
#
# helpers/history.py — network identity over a store that spans four
# versions of netdiag's own identity scheme. The failure modes are all
# silent: a chart that merges two networks, or splits one, looks exactly
# like a chart that didn't.
#
# Synthetic records rather than captured ones: every test states the
# minimum fields the grouping rule under test actually reads, so a reader
# can see what the rule keys off without diffing two 5 KB snapshots.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  TMP="$BATS_TEST_TMPDIR"
  LIVE="$TMP/baseline.jsonl"
  ARCHIVE="$TMP/baseline-archive.jsonl"
  : > "$LIVE"
  # metric_stats (per-network median/p10/p90) reuses --show's comparison
  # arithmetic, so the plain listing now needs THRESH_COMPARE_* too.
  # Sourced rather than hardcoded, so a test can never pass against a
  # cutoff production does not use. bin/netdiag exports exactly these.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export THRESH_COMPARE_MIN_SAMPLES THRESH_COMPARE_TAIL_PCTL
}

# rec <file> <ts> <json-body…> — append one record. The body is spliced in
# so each test writes only the fields it cares about.
rec() {
  local file="$1" ts="$2"; shift 2
  printf '{"version":"0.6.0","timestamp":"%s"%s}\n' "$ts" "${1:+,$1}" >> "$file"
}

hist() {
  python3 "$HELPERS/history.py" --history "$LIVE" "$@"
}

# `run` takes a command, not a pipeline, and `run bash -c` would spawn a
# shell that has none of these helpers. Wrap the pipe instead.
hget() {
  local path="$1"; shift
  hist "$@" | get "$path"
}

hpy() {
  local script="$1"; shift
  hist "$@" | python3 -c "$script"
}

# Pull one value out of the emitted object with a dotted/indexed path.
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

# ── MAC grouping ─────────────────────────────────────────────────────────
# The id of one network changes the day Location Services is granted:
# "wifi:mac=X" becomes "wifi:ssid=Home,mac=X". Exact-string matching would
# split a single network's history in half at that moment.

# netid_run (lib/netid.sh) publishes NETWORK_GROUP — the group key a live
# consumer joins this history with — as a sibling of the raw record id it
# derives it from. That derivation is a *second copy* of this file's
# group_key precedence, living in bash so the monitor does not spawn
# python per sample, and copies drift. This test is the pin: for one
# record of each id shape, netid_run's NETWORK_GROUP must equal the id
# history.py actually grouped that record under. If someone changes
# either side alone, this goes red.
netid_group() {
  local id="$1" kind="${2:-wifi}"
  local IS_WIFI=0
  [ "$kind" = "wifi" ] && IS_WIFI=1
  local WIFI_SSID="" GW_MAC="" GATEWAY="" NETWORK_ID="" NETWORK_LABEL="" NETWORK_GROUP=""
  local ssid=""
  case "$id" in
    *ssid=*|wifi:ssid=*) ssid="${id#*ssid=}"; ssid="${ssid%%,*}"; WIFI_SSID="$ssid" ;;
  esac
  case "$id" in
    *mac=*) GW_MAC="${id#*mac=}" ;;
  esac
  case "$id" in
    *gw=*) GATEWAY="${id#*gw=}" ;;
  esac
  netid_run >/dev/null 2>&1 || true
  printf '%s' "$NETWORK_GROUP"
}

@test "netid_run's NETWORK_GROUP equals the group key history.py assigns" {
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
  # One record per id shape; the join must hold for every one of them.
  local ids=(
    'wifi:mac=aa:bb:cc:dd:ee:ff'
    'wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff'
    'lan:mac=aa:bb:cc:dd:ee:ff'
    'lan:gw=192.168.1.1'
    'wifi:ssid=Cafe'
  )
  local i=0
  for id in "${ids[@]}"; do
    rec "$LIVE" "2026-01-0$((++i))T00:00:00Z" "\"network\":{\"id\":\"$id\"}"
  done
  # For each id shape, netid_group must produce a key that IS one of
  # history.py's group ids — not merely well-formed.
  local groups_json
  groups_json="$(hist | python3 -c 'import json,sys; print(" ".join(n["id"] for n in json.load(sys.stdin)["networks"]))')"
  for id in "${ids[@]}"; do
    local g
    g="$(netid_group "$id")"
    run bash -c "printf '%s' '$groups_json' | grep -qw '$g'"
    [ "$status" -eq 0 ] || { echo "netid_group($id) = '$g' but history groups are: $groups_json"; return 1; }
  done
}

@test "runs before and after an SSID becomes visible stay one network" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff","label":"WiFi (SSID hidden by macOS)"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff","label":"Home"}'
  run hget counts.networks
  [ "$output" = "1" ]
}

@test "the surviving group is keyed on the MAC and prefers the real label" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff","label":"WiFi (SSID hidden by macOS)"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff","label":"Home"}'
  run hget networks.0.id
  [ "$output" = '"mac:aa:bb:cc:dd:ee:ff"' ]
  run hget networks.0.label
  [ "$output" = '"Home"' ]
}

@test "MAC comparison is case-insensitive" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=AA:BB:CC:DD:EE:FF"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget counts.networks
  [ "$output" = "1" ]
}

@test "two different routers stay two networks" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=11:22:33:44:55:66"}'
  run hget counts.networks
  [ "$output" = "2" ]
}

# ── Legacy backfill ──────────────────────────────────────────────────────
# 1,926 of the author's 1,972 records predate lib/netid.sh and carry no
# network.id at all. Skipping them would throw away 98% of the history;
# pooling them into one bucket would invent a network that never existed.

@test "a record with no network.id is backfilled from its gateway MAC" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"}'
  run hget networks.0.id
  [ "$output" = '"mac:aa:bb:cc:dd:ee:ff"' ]
}

@test "backfill falls back to SSID when no gateway MAC was recorded" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"wifi":{"ssid":"CafeNet"},"interface":{"gateway":"10.0.0.1"}'
  run hget networks.0.id
  [ "$output" = '"ssid:CafeNet"' ]
}

@test "backfill falls back to gateway IP when the SSID is OS-redacted" {
  # This is the real case: every legacy record here carries the literal
  # string "<redacted>" as its SSID. Treating that as a name would collapse
  # every network the machine has ever seen into one group.
  rec "$LIVE" 2026-01-01T00:00:00Z '"wifi":{"ssid":"<redacted>"},"interface":{"gateway":"192.168.50.1"}'
  run hget networks.0.id
  [ "$output" = '"gw:192.168.50.1"' ]
}

@test "a backfilled group is marked synthesized" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.50.1"}'
  run hget networks.0.synthesized
  [ "$output" = "true" ]
}

@test "a group derived from a recorded network.id is not marked synthesized" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget networks.0.synthesized
  [ "$output" = "false" ]
}

@test "a record with no identity at all lands in 'unknown', not in someone else's group" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"interface":{}'
  run hget counts.networks
  [ "$output" = "2" ]
  run hpy 'import json,sys; print(sorted(n["id"] for n in json.load(sys.stdin)["networks"]))'
  [[ "$output" == *"unknown"* ]]
}

# ── The bridge heuristic ─────────────────────────────────────────────────

@test "a legacy gateway group bridges into the MAC group it shares a router and ISP with" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget counts.networks
  [ "$output" = "1" ]
  run hget networks.0.run_count
  [ "$output" = "2" ]
  run hget networks.0.bridged_from
  [ "$output" = '["gw:192.168.1.1"]' ]
}

@test "a bridged group is marked synthesized — the merge is inference, not a record" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget networks.0.synthesized
  [ "$output" = "true" ]
}

@test "a bridge widens the group's date range to cover the legacy runs" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-06-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget networks.0.first_seen
  [ "$output" = '"2026-01-01T00:00:00Z"' ]
  run hget networks.0.last_seen
  [ "$output" = '"2026-06-01T00:00:00Z"' ]
}

@test "no bridge when the ISP differs — same private range, different continent" {
  # 192.168.1.1 is the most common LAN address on earth. Matching on it
  # alone would merge a home network with a hotel's.
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"STARLINK"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"TELEFONICA"}'
  run hget counts.networks
  [ "$output" = "2" ]
}

@test "no bridge when the gateway differs even though the ISP matches" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.50.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.15.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget counts.networks
  [ "$output" = "2" ]
}

@test "an ambiguous bridge is left for the user rather than guessed" {
  # Two MAC groups match the same evidence. Picking either would be a coin
  # flip that silently corrupts a chart; the app offers a manual merge.
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-03T00:00:00Z '"network":{"id":"wifi:mac=11:22:33:44:55:66"},"interface":{"gateway":"192.168.1.1","gateway_mac":"11:22:33:44:55:66"},"public":{"isp":"ACME ISP"}'
  run hget counts.networks
  [ "$output" = "3" ]
}

@test "a conflicting WiFi channel vetoes a bridge that gateway and ISP would allow" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"wifi":{"channel":"2g6/20"},"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"wifi":{"channel":"5g149/40"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget counts.networks
  [ "$output" = "2" ]
}

@test "a channel known on only one side does not veto — legacy runs rarely recorded it" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"interface":{"gateway":"192.168.1.1"},"public":{"isp":"ACME ISP"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"wifi":{"channel":"5g149/40"},"interface":{"gateway":"192.168.1.1","gateway_mac":"aa:bb:cc:dd:ee:ff"},"public":{"isp":"ACME ISP"}'
  run hget counts.networks
  [ "$output" = "1" ]
}

# ── Redacted records ─────────────────────────────────────────────────────

@test "records whose identity was redacted are dropped and counted" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=[redacted]"},"interface":{"gateway_mac":"[redacted]"}'
  run hget counts.redacted_dropped
  [ "$output" = "1" ]
  run hget counts.runs
  [ "$output" = "1" ]
}

@test "a redacted record never becomes a phantom network" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=[redacted]"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=[redacted]"}'
  run hget counts.networks
  [ "$output" = "0" ]
}

# ── Archive + live ───────────────────────────────────────────────────────

@test "the archive is read alongside the live file" {
  rec "$ARCHIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE"    2026-06-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget counts.runs
  [ "$output" = "2" ]
  run hget networks.0.first_seen
  [ "$output" = '"2026-01-01T00:00:00Z"' ]
}

@test "an archive/live overlap is deduped rather than double-counted" {
  # prune_history appends to the archive before truncating the live file,
  # so a crash between the two leaves byte-identical records in both.
  rec "$ARCHIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE"    2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget counts.runs
  [ "$output" = "1" ]
  run hget counts.duplicates_dropped
  [ "$output" = "1" ]
}

@test "two distinct runs in the same second are both kept" {
  # Timestamps have one-second resolution and back-to-back manual runs do
  # collide. Deduping on timestamp alone would delete a real measurement.
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":3.1}'
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":9.7}'
  run hget counts.runs
  [ "$output" = "2" ]
}

@test "a missing archive is not an error" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  [ ! -e "$ARCHIVE" ]
  run hget sources.archive
  [ "$output" = "null" ]
}

@test "an unparseable line is counted, not fatal" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  printf 'not json at all\n' >> "$LIVE"
  run hget counts.unparseable_dropped
  [ "$output" = "1" ]
}

@test "an empty history still emits a valid, complete object" {
  run hist
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for k in ('schema','sources','counts','metrics','networks','runs'):
    assert k in d, k
assert d['runs'] == [] and d['networks'] == []
"
}

# ── Run rows ─────────────────────────────────────────────────────────────

@test "severity is the worst diagnosis in the run, and info does not count as a fault" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"diagnosis":[{"severity":"info","rule":"VPN-1","summary":"x"},{"severity":"warn","rule":"G3","summary":"y"},{"severity":"critical","rule":"L1","summary":"z"}]'
  run hget runs.0.severity
  [ "$output" = '"critical"' ]
  run hget runs.0.diagnosis_count
  [ "$output" = "2" ]
  run hget runs.0.rules
  [ "$output" = '["VPN-1", "G3", "L1"]' ]
}

@test "a run with no diagnoses is 'ok'" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"diagnosis":[]'
  run hget runs.0.severity
  [ "$output" = '"ok"' ]
}

@test "an unmeasured metric is absent rather than zero" {
  # The whole reason JSON-SCHEMA.md distinguishes null from 0: a chart that
  # plots "not measured" as 0 draws a cliff that never happened.
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":3.4,"loss_pct":null}'
  run hget runs.0.metrics
  [ "$output" = '{"gateway_rtt_ms": 3.4}' ] || [ "$output" = '{"gateway_rtt_ms":3.4}' ]
}

@test "every metric reports how many samples back it" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":3.4}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":4.1},"wifi":{"rssi":-55}'
  run hpy 'import json,sys; m={x["key"]:x["samples"] for x in json.load(sys.stdin)["metrics"]}; print(m["gateway_rtt_ms"], m["wifi_rssi_dbm"], m["speed_down_mbps"])'
  [ "$output" = "2 1 0" ]
}

@test "a metric with no samples is still listed, so the UI can say 'no data'" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":3.4}'
  run hpy 'import json,sys; print(len(json.load(sys.stdin)["metrics"]))'
  [ "$output" -ge 13 ]
}

# ── metric_stats: population facts, no verdict ────────────────────────────
# median/p10/p90 over the same per-network population metric_samples
# counts, reusing --show's own quantile()/median arithmetic. No verdict,
# no direction, no value: --history states what a network's numbers look
# like; whether any one run's reading was good stays --show's question.

# ramp <metric-json> — twenty runs on one network, one per day, with every
# @ replaced by the day number, mirroring test_show.bats's own fixture:
# median 10.5, and with the default 10-point tail p10 is 2.9 and p90 18.1.
ramp() {
  local body="$1" i
  for i in $(seq 1 20); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" \
      "\"network\":{\"id\":\"wifi:mac=aa:bb:cc:dd:ee:ff\"},${body//@/$i}"
  done
}

@test "metric_stats carries every METRICS key, present or null" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"gateway":{"rtt_avg_ms":3.4}'
  run hpy 'import json,sys
d = json.load(sys.stdin)
keys = sorted(m["key"] for m in d["metrics"])
print(keys == sorted(d["networks"][0]["metric_stats"]))'
  [ "$output" = "True" ]
}

@test "median, p10 and p90 come off the raw distribution, same arithmetic as --show" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run hget networks.0.metric_stats.gateway_rtt_ms.median
  [ "$output" = "10.5" ]
  run hget networks.0.metric_stats.gateway_rtt_ms.p10
  [ "$output" = "2.9" ]
  run hget networks.0.metric_stats.gateway_rtt_ms.p90
  [ "$output" = "18.1" ]
}

@test "metric_stats is facts only — no value, direction or verdict" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run hpy 'import json,sys
s = json.load(sys.stdin)["networks"][0]["metric_stats"]["gateway_rtt_ms"]
print(sorted(s))'
  [ "$output" = "['median', 'p10', 'p90']" ]
}

@test "below THRESH_COMPARE_MIN_SAMPLES the whole metric_stats block is null" {
  local i
  for i in $(seq 1 $((THRESH_COMPARE_MIN_SAMPLES - 1))); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" \
      "\"network\":{\"id\":\"wifi:mac=aa:bb:cc:dd:ee:ff\"},\"gateway\":{\"rtt_avg_ms\":$i.0}"
  done
  run hget networks.0.metric_stats.gateway_rtt_ms
  [ "$output" = "null" ]
  # metric_samples still reports the count — a UI reads "n" from there,
  # not from inside a null metric_stats block.
  run hget networks.0.metric_samples.gateway_rtt_ms
  [ "$output" = "$((THRESH_COMPARE_MIN_SAMPLES - 1))" ]
}

@test "one more sample crosses into a real metric_stats block" {
  local i
  for i in $(seq 1 "$THRESH_COMPARE_MIN_SAMPLES"); do
    rec "$LIVE" "$(printf '2026-01-%02dT00:00:00Z' "$i")" \
      "\"network\":{\"id\":\"wifi:mac=aa:bb:cc:dd:ee:ff\"},\"gateway\":{\"rtt_avg_ms\":$i.0}"
  done
  run hget networks.0.metric_stats.gateway_rtt_ms
  [ "$output" != "null" ]
}

@test "metric_stats is scoped to the network — another network's samples don't leak in" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  rec "$LIVE" 2026-02-01T00:00:00Z '"network":{"id":"wifi:mac=11:22:33:44:55:66"},"gateway":{"rtt_avg_ms":900.0}'
  run hget networks.0.metric_stats.gateway_rtt_ms.median
  [ "$output" = "10.5" ]
}

@test "metric_stats and metric_samples agree on n, and both follow --limit" {
  ramp '"gateway":{"rtt_avg_ms":@.0}'
  run hget networks.0.metric_samples.gateway_rtt_ms --limit 5
  local limited_samples="$output"
  [ "$limited_samples" = "5" ]
  run hpy 'import json,sys; print(json.load(sys.stdin)["networks"][0]["metric_stats"]["gateway_rtt_ms"])' --limit 5
  # Fewer than THRESH_COMPARE_MIN_SAMPLES (10) of the 5 most recent runs,
  # so the population is too thin for a stats block at all.
  [ "$output" = "None" ]
}

@test "--history refuses to run without THRESH_COMPARE_* — metric_stats needs them too now" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run env -u THRESH_COMPARE_MIN_SAMPLES -u THRESH_COMPARE_TAIL_PCTL \
    python3 "$HELPERS/history.py" --history "$LIVE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_COMPARE_MIN_SAMPLES"* ]]
  [[ "$output" == *"lib/thresholds.sh"* ]]
}

@test "--limit keeps the most recent runs" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-03T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget runs.0.ts --limit 2
  [ "$output" = '"2026-01-02T00:00:00Z"' ]
}

@test "runs come out in chronological order regardless of file order" {
  rec "$LIVE" 2026-03-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget runs.0.ts
  [ "$output" = '"2026-01-01T00:00:00Z"' ]
}

# ── run_mode: not every stored run is a check ────────────────────────────
# A --speed-only run measures throughput and forms no opinion about the
# network. Counting it as a check is what let "1,986 checks" describe a
# store full of spot readings.

@test "a partial run contributes its metrics" {
  # This is the entire point of storing it: throughput is the sparsest
  # series in the store, and --speed-only is the cheap way to thicken it.
  rec "$LIVE" 2026-01-01T00:00:00Z '"run_mode":"speed-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"speedtest":{"down_mbps":331.3}'
  run hpy 'import json,sys; m={x["key"]:x["samples"] for x in json.load(sys.stdin)["metrics"]}; print(m["speed_down_mbps"])'
  [ "$output" = "1" ]
}

@test "a partial run does not vote on the network's severity" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"run_mode":"full","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"diagnosis":[{"severity":"warn","rule":"G3","summary":"x"}]'
  rec "$LIVE" 2026-01-02T00:00:00Z '"run_mode":"speed-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"diagnosis":[{"severity":"critical","rule":"G2","summary":"x"}]'
  run hget networks.0.severity_counts
  [ "$output" = '{"warn": 1}' ] || [ "$output" = '{"warn":1}' ]
}

@test "run_count counts every record and check_count only the real checks" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"run_mode":"full","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"run_mode":"quick","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-03T00:00:00Z '"run_mode":"speed-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-04T00:00:00Z '"run_mode":"mtu-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget networks.0.run_count
  [ "$output" = "4" ]
  run hget networks.0.check_count
  [ "$output" = "2" ]
  run hget counts.checks
  [ "$output" = "2" ]
}

@test "a record with no run_mode still counts as a check" {
  # 1,986 records predate the field. Absence has to decode as "unknown,
  # treat as a check" or shipping this would have rewritten two months of
  # history into spot readings.
  rec "$LIVE" 2026-01-01T00:00:00Z '"network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"},"diagnosis":[{"severity":"warn","rule":"G3","summary":"x"}]'
  run hget networks.0.check_count
  [ "$output" = "1" ]
  run hget networks.0.severity_counts
  [ "$output" = '{"warn": 1}' ] || [ "$output" = '{"warn":1}' ]
  run hget runs.0.run_mode
  [ "$output" = "null" ]
}

@test "a future --dns-only would be recognised as partial without a code change" {
  # The rule is the -only suffix, not a list of the three modes that exist
  # today: a list goes stale silently, by counting a new partial mode as a
  # full check.
  rec "$LIVE" 2026-01-01T00:00:00Z '"run_mode":"dns-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run hget networks.0.check_count
  [ "$output" = "0" ]
}

@test "--show separates the runs on a network from the checks on it" {
  rec "$LIVE" 2026-01-01T00:00:00Z '"run_mode":"full","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  rec "$LIVE" 2026-01-02T00:00:00Z '"run_mode":"speed-only","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}'
  run bash -c "THRESH_COMPARE_MIN_SAMPLES=5 THRESH_COMPARE_TAIL_PCTL=10 \
    python3 '$HELPERS/history.py' --history '$LIVE' --show 2026-01-01T00:00:00Z \
    | python3 -c 'import json,sys; c=json.load(sys.stdin)[\"context\"]; print(c[\"runs_on_network\"], c[\"checks_on_network\"])'"
  [ "$output" = "2 1" ]
}

# ── CLI surface ──────────────────────────────────────────────────────────

@test "--history emits one parseable object and exits 0" {
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --history"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "--history with a non-numeric limit exits 3, not 2" {
  run bash -c "HOME='$TMP' '$REPO/bin/netdiag' --history=soon"
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a run count"* ]]
}

@test "--history is documented in --help" {
  run "$REPO/bin/netdiag" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--history"* ]]
}
