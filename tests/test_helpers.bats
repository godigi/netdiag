#!/usr/bin/env bats
#
# Tests for helpers/*.py. emit_json.py is the widest interface in the
# project — every JSON consumer depends on its shape — and had no coverage
# at all, so a renamed global silently produced null and nothing noticed.
# It's pure (NETDIAG_* env in, JSON out), so it's cheap to pin down.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  TMP="$BATS_TEST_TMPDIR"
}

# Run emit_json.py with only the NETDIAG_* vars given as KEY=VALUE args,
# so each test states exactly the input it depends on.
emit() {
  env -i PATH="$PATH" "$@" python3 "$HELPERS/emit_json.py"
}

jq_get() {
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split('.'):
    d = d[int(k)] if k.isdigit() else d.get(k)
    if d is None: break
print(json.dumps(d, ensure_ascii=False))
" "$1"
}

# ── emit_json: shape ─────────────────────────────────────────────────────

@test "emit_json: empty environment still produces valid JSON" {
  run emit
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "emit_json: every documented top-level key is present" {
  run emit
  [ "$status" -eq 0 ]
  for key in version timestamp run_mode interface network wifi gateway internet_latency \
             public dns traceroute per_hop bufferbloat mtu ipv6 vpn tcp_reach \
             wifi_scan wifi_disconnects speedtest ntp duplicate_ips dhcp mtr \
             wan hosts_file timings baseline diagnosis most_likely_root_cause \
             netdiag_extras; do
    got="$(printf '%s' "$output" | python3 -c "
import json,sys; print('yes' if '$key' in json.load(sys.stdin) else 'no')")"
    [ "$got" = "yes" ] || { echo "missing top-level key: $key"; return 1; }
  done
}

@test "emit_json: run_id is absent unless the caller set NETDIAG_RUN_ID" {
  # The one top-level key that is NOT unconditionally present, unlike
  # every key the previous test checks. lib/output.sh's private build —
  # the one that becomes the appended baseline.jsonl record — never sets
  # this var, deliberately: the key must not exist in that build's output
  # at all, so it can never sit inside the bytes history.py hashes to
  # produce the very id it would carry. Only the render built for stdout
  # sets it, even to an empty string when no record was appended.
  run emit
  [ "$(printf '%s' "$output" | python3 -c "import json,sys; print('run_id' in json.load(sys.stdin))")" = "False" ]

  run emit NETDIAG_RUN_ID=2026-01-01T00:00:00Z.deadbeef
  [ "$(printf '%s' "$output" | jq_get run_id)" = '"2026-01-01T00:00:00Z.deadbeef"' ]

  # Set-but-empty (what lib/output.sh passes when this run didn't append)
  # reads as present-and-null, not absent — the two are different facts.
  run emit NETDIAG_RUN_ID=
  [ "$(printf '%s' "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print('run_id' in d, d.get('run_id'))")" = "True None" ]
}

@test "emit_json: run_mode is carried through, and is null when unset" {
  # Null rather than a "full" default: this helper is also run by hand and
  # from the bats suite, and a default would let a record claim it was a
  # full check when nothing ever said so.
  run emit NETDIAG_RUN_MODE=speed-only
  [ "$(printf '%s' "$output" | jq_get run_mode)" = '"speed-only"' ]
  run emit
  [ "$(printf '%s' "$output" | jq_get run_mode)" = "null" ]
}

@test "emit_json: wifi/wifi_scan are null on a wired run" {
  run emit NETDIAG_IS_WIFI=0
  [ "$(printf '%s' "$output" | jq_get wifi)" = "null" ]
  [ "$(printf '%s' "$output" | jq_get wifi_scan)" = "null" ]
  [ "$(printf '%s' "$output" | jq_get interface.type)" = '"wired"' ]
}

# ── emit_json: diagnosis rule IDs ────────────────────────────────────────

@test "emit_json: diagnosis lines carry their rule ID" {
  run emit NETDIAG_DIAGNOSIS_LINES='critical|N1|No network at all.
warn|M1|Path MTU is clamped.'
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.rule)" = '"N1"' ]
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.severity)" = '"critical"' ]
  [ "$(printf '%s' "$output" | jq_get diagnosis.1.rule)" = '"M1"' ]
}

@test "emit_json: a summary containing '|' survives the split" {
  run emit NETDIAG_DIAGNOSIS_LINES='warn|D1|Try 1.1.1.1 | 8.8.8.8 instead.'
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.rule)" = '"D1"' ]
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.summary)" = '"Try 1.1.1.1 | 8.8.8.8 instead."' ]
}

@test "emit_json: pre-0.5 two-field diagnosis lines still parse" {
  # Old baseline.jsonl records have no rule field. They must not be
  # mangled into severity="warn", rule="<the whole sentence>".
  run emit NETDIAG_DIAGNOSIS_LINES='warn|Something changed since your last runs.'
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.severity)" = '"warn"' ]
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.rule)" = "null" ]
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.summary)" = '"Something changed since your last runs."' ]
}

# ── emit_json: hops with gaps ────────────────────────────────────────────

@test "emit_json: a non-responding hop keeps its number and reports ip null" {
  run emit NETDIAG_TRACE_LINES='1|192.168.1.1|3.0
2||
3|10.0.0.1|10.0'
  [ "$(printf '%s' "$output" | jq_get traceroute.hops.1.n)" = "2" ]
  [ "$(printf '%s' "$output" | jq_get traceroute.hops.1.ip)" = "null" ]
  [ "$(printf '%s' "$output" | jq_get traceroute.hops.1.responded)" = "false" ]
  [ "$(printf '%s' "$output" | jq_get traceroute.hops.2.n)" = "3" ]
  [ "$(printf '%s' "$output" | jq_get traceroute.hops.2.responded)" = "true" ]
}

@test "emit_json: mtr's '???' placeholder normalises to ip null" {
  run emit NETDIAG_PER_HOP_LINES='4|???|100.0|'
  [ "$(printf '%s' "$output" | jq_get per_hop.0.ip)" = "null" ]
  [ "$(printf '%s' "$output" | jq_get per_hop.0.responded)" = "false" ]
}

# ── emit_json: NAT split and network identity ────────────────────────────

@test "emit_json: empty NAT chains yield [] and not ['']" {
  run emit
  [ "$(printf '%s' "$output" | jq_get wan.double_nat.home_chain)" = "[]" ]
  [ "$(printf '%s' "$output" | jq_get wan.double_nat.isp_transit_chain)" = "[]" ]
}

@test "emit_json: NAT chains split into home and ISP transit" {
  run emit NETDIAG_WAN_NAT_HOME_CHAIN='192.168.68.1 → 192.168.58.1' \
           NETDIAG_WAN_NAT_HOME_COUNT=2 \
           NETDIAG_WAN_NAT_ISP_CHAIN='10.1.1.1' \
           NETDIAG_WAN_NAT_ISP_COUNT=1 \
           NETDIAG_WAN_DOUBLE_NAT=1
  [ "$(printf '%s' "$output" | jq_get wan.double_nat.home_count)" = "2" ]
  [ "$(printf '%s' "$output" | jq_get wan.double_nat.detected)" = "true" ]
  [ "$(printf '%s' "$output" | jq_get wan.double_nat.isp_transit_count)" = "1" ]
}

@test "emit_json: timings report the budget the run was measured against" {
  run emit NETDIAG_TIMING_LINES='iface|0.02
mtu|12.50' NETDIAG_RUN_ELAPSED_S=42.0 NETDIAG_QUICK=0
  [ "$(printf '%s' "$output" | jq_get timings.total_s)" = "42.0" ]
  [ "$(printf '%s' "$output" | jq_get timings.budget_s)" = "30.0" ]
  [ "$(printf '%s' "$output" | jq_get timings.over_budget)" = "true" ]
  [ "$(printf '%s' "$output" | jq_get timings.phases.mtu)" = "12.5" ]
}

@test "emit_json: --quick runs are measured against the 8 s budget" {
  run emit NETDIAG_RUN_ELAPSED_S=7.5 NETDIAG_QUICK=1
  [ "$(printf '%s' "$output" | jq_get timings.budget_s)" = "8.0" ]
  [ "$(printf '%s' "$output" | jq_get timings.over_budget)" = "false" ]
}

# ── baseline.py: history is scoped by network ────────────────────────────
# Regression guard for the laptop case: without scoping, moving between
# networks tripped "gateway RTT spike" / "ISP changed" every time.

_write_history() {
  # $1 = file, $2 = network id, $3 = count, $4 = gateway rtt
  local f="$1" nid="$2" n="$3" rtt="$4" i
  for i in $(seq 1 "$n"); do
    printf '{"network":{"id":"%s"},"gateway":{"rtt_avg_ms":%s},"public":{"isp":"ISP-%s"}}\n' \
      "$nid" "$rtt" "$nid" >> "$f"
  done
}

@test "baseline: a spike on the same network is reported" {
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  _write_history "$hist" "wifi:ssid=Home" 5 3.0
  printf '{"network":{"id":"wifi:ssid=Home"},"gateway":{"rtt_avg_ms":40.0},"public":{"isp":"ISP-wifi:ssid=Home"}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "5" ]
  [[ "$output" == *"gateway RTT"* ]]
}

@test "baseline: history from other networks is skipped, not compared" {
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  _write_history "$hist" "wifi:ssid=Cafe" 8 3.0
  printf '{"network":{"id":"wifi:ssid=Home"},"gateway":{"rtt_avg_ms":40.0}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur"
  [ "$status" -eq 0 ]
  # Nothing on this network yet → nothing to compare, and no regressions.
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "0" ]
  [ "$(printf '%s' "$output" | jq_get regressions)" = "[]" ]
  [ "$(printf '%s' "$output" | jq_get skipped_other_networks)" = "8" ]
}

@test "baseline: same-network runs are selected out of a mixed file" {
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  _write_history "$hist" "wifi:ssid=Home" 4 3.0
  _write_history "$hist" "wifi:ssid=Cafe" 6 90.0
  printf '{"network":{"id":"wifi:ssid=Home"},"gateway":{"rtt_avg_ms":3.2}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur"
  # Only the 4 Home runs are comparable; 3.2 ms against a 3.0 ms median is
  # not a regression, even though the file's overall median is far higher.
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "4" ]
  [ "$(printf '%s' "$output" | jq_get regressions)" = "[]" ]
  [ "$(printf '%s' "$output" | jq_get skipped_other_networks)" = "6" ]
}

@test "baseline: filtering happens before the last-N window" {
  # 5 Home runs, then 20 Cafe runs. Taking the tail first would leave zero
  # Home records inside a 10-run window and silently skip the comparison.
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  _write_history "$hist" "wifi:ssid=Home" 5 3.0
  _write_history "$hist" "wifi:ssid=Cafe" 20 90.0
  printf '{"network":{"id":"wifi:ssid=Home"},"gateway":{"rtt_avg_ms":40.0}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur" --n 10
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "5" ]
  [[ "$output" == *"gateway RTT"* ]]
}

@test "baseline: a run with no network identity is not compared" {
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  _write_history "$hist" "wifi:ssid=Home" 5 3.0
  printf '{"network":{"id":null},"gateway":{"rtt_avg_ms":40.0}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur"
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "0" ]
  [ "$(printf '%s' "$output" | jq_get regressions)" = "[]" ]
}

@test "baseline: pre-0.5 records without network.id are not pooled in" {
  hist="$TMP/h.jsonl"; cur="$TMP/c.json"
  for _ in 1 2 3 4 5; do
    printf '{"gateway":{"rtt_avg_ms":3.0}}\n' >> "$hist"
  done
  printf '{"network":{"id":"wifi:ssid=Home"},"gateway":{"rtt_avg_ms":40.0}}' > "$cur"
  run python3 "$REPO/helpers/baseline.py" --history "$hist" --current "$cur"
  [ "$(printf '%s' "$output" | jq_get compared_runs)" = "0" ]
  [ "$(printf '%s' "$output" | jq_get regressions)" = "[]" ]
}

# ── emit_json: --redact ──────────────────────────────────────────────────

@test "emit_json redact: masks identifying fields, keeps ISP and private IPs" {
  run emit NETDIAG_REDACT=1 NETDIAG_IS_WIFI=1 \
           NETDIAG_PUB_IP=203.0.113.42 NETDIAG_WIFI_SSID=BrianHomeNet \
           NETDIAG_PUB_ISP='Example ISP' NETDIAG_GATEWAY=192.168.1.1
  [ "$(printf '%s' "$output" | jq_get public.ip)" = '"[redacted]"' ]
  [ "$(printf '%s' "$output" | jq_get wifi.ssid)" = '"[redacted]"' ]
  [ "$(printf '%s' "$output" | jq_get public.isp)" = '"Example ISP"' ]
  [ "$(printf '%s' "$output" | jq_get interface.gateway)" = '"192.168.1.1"' ]
}

@test "emit_json redact: scrubs values interpolated into diagnosis prose" {
  run emit NETDIAG_REDACT=1 NETDIAG_PUB_IP=203.0.113.42 \
           NETDIAG_DIAGNOSIS_LINES='warn|P2|No reply at 203.0.113.42 today.'
  [[ "$output" != *"203.0.113.42"* ]]
  [ "$(printf '%s' "$output" | jq_get diagnosis.0.summary)" = '"No reply at [redacted] today."' ]
}

@test "emit_json: without --redact nothing is masked" {
  run emit NETDIAG_PUB_IP=203.0.113.42 NETDIAG_IS_WIFI=1 NETDIAG_WIFI_SSID=BrianHomeNet
  [ "$(printf '%s' "$output" | jq_get public.ip)" = '"203.0.113.42"' ]
  [ "$(printf '%s' "$output" | jq_get wifi.ssid)" = '"BrianHomeNet"' ]
}

@test "emit_json redact: network id keeps its structure, masks only the secrets" {
  run emit NETDIAG_REDACT=1 NETDIAG_IS_WIFI=1 \
           NETDIAG_WIFI_SSID=BrianHomeNet NETDIAG_GW_MAC='aa:bb:cc:dd:ee:01' \
           NETDIAG_NETWORK_ID='wifi:ssid=BrianHomeNet,mac=aa:bb:cc:dd:ee:01' \
           NETDIAG_NETWORK_LABEL=BrianHomeNet
  [[ "$output" != *"BrianHomeNet"* ]]
  [[ "$output" != *"aa:bb:cc:dd:ee:01"* ]]
  # The composite keeps its readable shape so the scoping stays debuggable.
  [ "$(printf '%s' "$output" | jq_get network.id)" = '"wifi:ssid=[redacted],mac=[redacted]"' ]
}

@test "emit_json redact: a generic network label is not treated as a secret" {
  run emit NETDIAG_REDACT=1 NETDIAG_NETWORK_LABEL='unknown network'
  [ "$(printf '%s' "$output" | jq_get network.label)" = '"unknown network"' ]
}

@test "emit_json redact: masks the IPv6 link-local gateway" {
  run emit NETDIAG_REDACT=1 \
           NETDIAG_IPV6_GATEWAY='fe80::1298:5fff:fe91:2f00%en0' \
           NETDIAG_IPV6_AVAILABLE=1
  [ "$(printf '%s' "$output" | jq_get ipv6.gateway)" = '"[redacted]"' ]
}

@test "emit_json redact: nulls run_id even though it isn't built from any secret" {
  # run_id doesn't match any string in _REDACT_ENV, so the ordinary
  # secret-scrub would leave it untouched. It is nulled by name instead:
  # a report built to leave the machine should not carry a working
  # pointer back into the private, unredacted record lib/output.sh always
  # stores.
  run emit NETDIAG_REDACT=1 NETDIAG_RUN_ID=2026-01-01T00:00:00Z.deadbeef
  [ "$(printf '%s' "$output" | jq_get run_id)" = "null" ]
}
