#!/usr/bin/env bats
#
# Parser-level unit tests for the lib/*.sh modules. These exercise the
# pure-shell parsing helpers with captured / synthetic fixtures so the
# checks behave deterministically without touching the network.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  # Minimum variables the modules expect to exist (set -u in netdiag main).
  JSON_MODE=0 QUIET=0 QUICK=0 LOG=/dev/null
  # thresholds.sh declares the cutoffs diagnosis.sh fires on; bin/netdiag
  # sources it before common.sh and so must every test that exercises a rule.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/traceroute.sh
  . "$REPO/lib/traceroute.sh"
  # shellcheck source=../lib/mtr.sh
  . "$REPO/lib/mtr.sh"
  # shellcheck source=../lib/wan.sh
  . "$REPO/lib/wan.sh"
}

# ── N1: no network at all must not report "healthy" ──────────────────────
# Regression guard. Every other rule short-circuits on missing data, so a
# machine with WiFi off used to produce zero diagnoses and exit 0.

@test "diagnosis: empty GATEWAY yields a critical and MAX_SEVERITY 2" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=""
  run diagnosis_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no network connection at all"* ]]
  [[ "$output" != *"Nothing obviously wrong"* ]]

  # Re-run in-process so the accumulator side effects are visible.
  GATEWAY=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "$MAX_SEVERITY" -eq 2 ]
  [ "${DIAG_SEV[0]}" = "critical" ]
}

@test "diagnosis: a present GATEWAY does not trip N1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1"
  GW_LOSS="0"
  PUBLIC_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "$MAX_SEVERITY" -eq 0 ]
  [ "${#DIAG[@]}" -eq 0 ]
}

# ── is_numeric guard ─────────────────────────────────────────────────────

@test "is_numeric: accepts integers, decimals, and signed values" {
  is_numeric 0
  is_numeric 42
  is_numeric -52
  is_numeric +0.001234
  is_numeric 3.485
  is_numeric .5
}

@test "is_numeric: rejects empty, dates, and unit-suffixed values" {
  ! is_numeric ""
  ! is_numeric "2026-08-07"
  ! is_numeric "-52 dBm"
  ! is_numeric "abc"
  ! is_numeric "1.2.3"
}

# ── sntp drift parse (position-independent) ──────────────────────────────

# The drift field is located by the "+/-" token, not by position, because
# ntp 4.2.8 prefixes the result line with a timestamp on macOS while other
# builds lead with the offset.
_sntp_drift() {
  awk '{ for (i = 1; i < NF; i++) if ($(i+1) == "+/-") d = $i }
       END { if (d != "") print d }'
}

@test "sntp parse: offset-first format" {
  result="$(printf '%s\n' '+0.047883 +/- 0.021456 time.apple.com 17.253.66.253' | _sntp_drift)"
  [ "$result" = "+0.047883" ]
}

@test "sntp parse: ntp 4.2.8 timestamp-prefixed format" {
  line='2026-08-07 12:00:00.123456 (+0000) +0.047883 +/- 0.021456 time.apple.com 17.253.66.253'
  result="$(printf '%s\n' "$line" | _sntp_drift)"
  [ "$result" = "+0.047883" ]
  # Regression guard: the old `awk {print $1}` returned the date here, which
  # then passed the `> 1` string comparison and reported a bogus clock skew.
  [ "$result" != "2026-08-07" ]
  is_numeric "$result"
}

@test "sntp parse: skips retry chatter, keeps the last result line" {
  input='sntp 4.2.8p15@1.3728-o Fri Feb 16 17:32:26 UTC 2024 (1)
kod_init_kod_db(): Cannot open KoD db file /var/db/ntp-kod
2026-08-07 12:00:00.123456 (+0000) +0.047883 +/- 0.021456 time.apple.com 17.253.66.253'
  result="$(printf '%s\n' "$input" | _sntp_drift)"
  [ "$result" = "+0.047883" ]
}

@test "sntp parse: unparseable output yields empty, not garbage" {
  result="$(printf '%s\n' 'sntp: no servers can be used, exiting' | _sntp_drift)"
  [ -z "$result" ]
}

# ── grade_bufferbloat (Waveform A-F thresholds) ──────────────────────────

@test "grade_bufferbloat: 0ms → A" {
  result="$(grade_bufferbloat 0)"
  [ "$result" = "A" ]
}

@test "grade_bufferbloat: +4.9ms → A (just under +5 cutoff)" {
  result="$(grade_bufferbloat 4.9)"
  [ "$result" = "A" ]
}

@test "grade_bufferbloat: +5ms → B" {
  result="$(grade_bufferbloat 5)"
  [ "$result" = "B" ]
}

@test "grade_bufferbloat: +29.9ms → B" {
  result="$(grade_bufferbloat 29.9)"
  [ "$result" = "B" ]
}

@test "grade_bufferbloat: +30ms → C" {
  result="$(grade_bufferbloat 30)"
  [ "$result" = "C" ]
}

@test "grade_bufferbloat: +60ms → D" {
  result="$(grade_bufferbloat 60)"
  [ "$result" = "D" ]
}

@test "grade_bufferbloat: +200ms → F" {
  result="$(grade_bufferbloat 200)"
  [ "$result" = "F" ]
}

@test "grade_bufferbloat: +500ms → F" {
  result="$(grade_bufferbloat 500)"
  [ "$result" = "F" ]
}

# ── traceroute parser ────────────────────────────────────────────────────

@test "_parse_trace_lines: real fixture produces 'n|ip|rtt' lines" {
  parsed="$(_parse_trace_lines < "$FIX/traceroute.txt")"
  # Should be at least 2 hops; each line should match the expected shape.
  line_count="$(printf '%s\n' "$parsed" | grep -c '^[0-9]')"
  [ "$line_count" -ge 2 ]
  # First hop number must be 1.
  first_n="$(printf '%s\n' "$parsed" | head -1 | cut -d'|' -f1)"
  [ "$first_n" = "1" ]
  # First IP should look like an IPv4 address.
  first_ip="$(printf '%s\n' "$parsed" | head -1 | cut -d'|' -f2)"
  [[ "$first_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "_parse_trace_lines: keeps traceroute's own hop numbers across a timeout" {
  input='1  192.168.1.1  3.0 ms
2  *
3  10.0.0.1  10.0 ms'
  parsed="$(printf '%s' "$input" | _parse_trace_lines)"
  # All three hops are emitted; the timeout keeps its slot with an empty ip
  # so hop 3 is still reported as hop 3, matching what traceroute printed.
  lines="$(printf '%s\n' "$parsed" | grep -c '^[0-9]')"
  [ "$lines" -eq 3 ]
  [ "$(printf '%s\n' "$parsed" | sed -n '2p')" = "2||" ]
  [ "$(printf '%s\n' "$parsed" | sed -n '3p' | cut -d'|' -f1)" = "3" ]
  [ "$(printf '%s\n' "$parsed" | sed -n '3p' | cut -d'|' -f2)" = "10.0.0.1" ]
}

@test "_parse_trace_lines: real fixture keeps hop 4 numbered 4 after the '*' at 3" {
  parsed="$(_parse_trace_lines < "$FIX/traceroute.txt")"
  # Fixture hop 3 is '*'; hop 4 is 10.166.41.210. Under the old
  # reply-counting scheme that address was reported as hop 3.
  [ "$(printf '%s\n' "$parsed" | sed -n '3p')" = "3||" ]
  [ "$(printf '%s\n' "$parsed" | sed -n '4p')" = "4|10.166.41.210|20.071" ]
  # Last hop of a 10-hop trace is still numbered 10.
  [ "$(printf '%s\n' "$parsed" | tail -1 | cut -d'|' -f1)" = "10" ]
}

@test "_wan_count_rfc1918_chain: a timeout between private hops stops the walk" {
  # Regression guard for the false double-NAT: hop 2 never answered, so
  # hop 3 must not be treated as chained behind hop 1.
  input='1|192.168.1.1|3.0
2||
3|192.168.2.1|9.0'
  chain="$(printf '%s' "$input" | _wan_count_rfc1918_chain)"
  [ "$chain" = "192.168.1.1" ]
  _wan_split_nat_chain "$chain"
  [ "$WAN_NAT_HOME_COUNT" -eq 1 ]
}

@test "_parse_trace_lines: skips banner line ('traceroute to …')" {
  input='traceroute to 1.1.1.1 (1.1.1.1), 18 hops max, 40 byte packets
1  192.168.1.1  3.0 ms'
  parsed="$(printf '%s' "$input" | _parse_trace_lines)"
  # Only the hop line should appear, numbered 1.
  lines="$(printf '%s\n' "$parsed" | grep -c '^[0-9]')"
  [ "$lines" -eq 1 ]
  first_ip="$(printf '%s\n' "$parsed" | head -1 | cut -d'|' -f2)"
  [ "$first_ip" = "192.168.1.1" ]
}

# ── mtr first-lossy-hop detection ────────────────────────────────────────

@test "parse_mtr_tsv: identifies first lossy hop when loss propagates downstream" {
  # mtr fixture: hops 1-3 clean, hop 4 jumps to 50% loss and it persists
  # to the destination → real forwarding loss starting at hop 4.
  MTR_FIRST_LOSSY_HOP=""
  tsv="$(jq -r '.report.hubs[] | [.count, .host, (.["Loss%"]|tostring), (.Avg|tostring)] | @tsv' < "$FIX/mtr.json")"
  parse_mtr_tsv <<<"$tsv"
  [[ "$MTR_FIRST_LOSSY_HOP" == *"hop 4"* ]]
  [[ "$MTR_FIRST_LOSSY_HOP" == *"203.0.113.5"* ]]
}

@test "parse_mtr_tsv: rate-limited middle hops with clean destination → empty" {
  # ICMP-rate-limit pattern: hops 4-5 show 100% loss but hop 6 (destination)
  # is clean. Data is making it through; the middle hops just deprioritise
  # ICMP TTL-Exceeded. This must NOT be flagged as a real lossy hop.
  MTR_FIRST_LOSSY_HOP=""
  tsv="$(jq -r '.report.hubs[] | [.count, .host, (.["Loss%"]|tostring), (.Avg|tostring)] | @tsv' < "$FIX/mtr_rate_limited.json")"
  parse_mtr_tsv <<<"$tsv"
  [ -z "$MTR_FIRST_LOSSY_HOP" ]
}

@test "parse_mtr_tsv: clean run leaves MTR_FIRST_LOSSY_HOP empty" {
  tsv='1	192.168.1.1	0.0	3.2
2	10.0.0.1	1.0	8.4
3	1.1.1.1	0.0	18.0'
  MTR_FIRST_LOSSY_HOP=""
  parse_mtr_tsv <<<"$tsv"
  [ -z "$MTR_FIRST_LOSSY_HOP" ]
}

# ── ARP duplicate detection (inline awk, no library function yet) ────────

@test "ARP parser: arp_dup fixture surfaces 192.168.50.10 as a duplicate" {
  arp_pairs="$(awk '/ at / && $4 != "(incomplete)" {
                      ip = $2; gsub(/[()]/, "", ip); print ip, $4
                    }' "$FIX/arp_dup.txt" | sort -u)"
  duplicates="$(printf '%s\n' "$arp_pairs" | awk '{print $1}' | uniq -d | tr '\n' ' ')"
  [[ "$duplicates" == *"192.168.50.10"* ]]
}

@test "ARP parser: clean fixture has no duplicates" {
  arp_pairs="$(awk '/ at / && $4 != "(incomplete)" {
                      ip = $2; gsub(/[()]/, "", ip); print ip, $4
                    }' "$FIX/arp_an.txt" | sort -u)"
  duplicates="$(printf '%s\n' "$arp_pairs" | awk '{print $1}' | uniq -d | tr '\n' ' ')"
  [ -z "${duplicates// /}" ]
}

# ── DHCP lease-end date math ─────────────────────────────────────────────

@test "DHCP lease math: future expiry yields a positive remaining-seconds" {
  # Use a fixed date one hour in the future relative to a captured 'now'.
  future_date="$(date -j -v +1H +'%m/%d/%Y %H:%M:%S' 2>/dev/null)"
  lease_end_epoch="$(date -j -f '%m/%d/%Y %H:%M:%S' "$future_date" +%s 2>/dev/null)"
  now_epoch="$(date +%s)"
  remaining_s=$((lease_end_epoch - now_epoch))
  # Should be ~3600 s; allow a wide margin for test scheduler jitter.
  [ "$remaining_s" -gt 3500 ]
  [ "$remaining_s" -lt 3700 ]
}

@test "DHCP lease math: past expiry yields negative remaining-seconds" {
  past_date="$(date -j -v -1H +'%m/%d/%Y %H:%M:%S' 2>/dev/null)"
  lease_end_epoch="$(date -j -f '%m/%d/%Y %H:%M:%S' "$past_date" +%s 2>/dev/null)"
  now_epoch="$(date +%s)"
  remaining_s=$((lease_end_epoch - now_epoch))
  [ "$remaining_s" -lt 0 ]
}

# ── PMTU computation ─────────────────────────────────────────────────────

@test "PMTU: payload 1472 implies effective 1500" {
  # The 28 is 8 (ICMP header) + 20 (IP header).
  size=1472
  effective=$((size + 28))
  [ "$effective" -eq 1500 ]
}

@test "PMTU: payload 1352 implies effective 1380 (under 1500 → clamp)" {
  size=1352
  effective=$((size + 28))
  [ "$effective" -eq 1380 ]
  [ "$effective" -lt 1500 ]
}

# ── WAN double-NAT chain walker ──────────────────────────────────────────

@test "_wan_count_rfc1918_chain: stops at first public hop" {
  input='1|192.168.50.1|3.0
2|192.168.1.254|6.0
3|10.166.41.210|20.0
4|10.166.41.209|30.0
5|200.24.35.200|40.0
6|1.1.1.1|80.0'
  chain="$(printf '%s' "$input" | _wan_count_rfc1918_chain)"
  # Four RFC1918 hops before the first public address.
  count="$(printf '%s' "$chain" | awk '{print NF}')"
  [ "$count" -eq 4 ]
  [[ "$chain" == "192.168.50.1 192.168.1.254 10.166.41.210 10.166.41.209" ]]
}

@test "_wan_count_rfc1918_chain: single RFC1918 hop → no double-NAT" {
  input='1|192.168.1.1|3.0
2|203.0.113.42|10.0'
  chain="$(printf '%s' "$input" | _wan_count_rfc1918_chain)"
  count="$(printf '%s' "$chain" | awk '{print NF}')"
  [ "$count" -eq 1 ]
  [ "$chain" = "192.168.1.1" ]
}

@test "_wan_count_rfc1918_chain: no RFC1918 hops → empty chain" {
  input='1|203.0.113.5|5.0
2|1.1.1.1|10.0'
  chain="$(printf '%s' "$input" | _wan_count_rfc1918_chain)"
  # awk emits no NF line on empty input, so the chain string is empty.
  [ -z "$chain" ]
}

# ── WAN home-vs-ISP chain split ──────────────────────────────────────────
# Only home-side hops (192.168/16, 172.16/12) count as double-NAT. ISP
# transit over 10/8 is normal carrier routing.

@test "_wan_split_nat_chain: two home routers → home_count 2, no ISP transit" {
  _wan_split_nat_chain "192.168.68.1 192.168.58.1"
  [ "$WAN_NAT_HOME_COUNT" -eq 2 ]
  [ "$WAN_NAT_HOME_CHAIN" = "192.168.68.1 → 192.168.58.1" ]
  [ "$WAN_NAT_ISP_COUNT" -eq 0 ]
  [ -z "$WAN_NAT_ISP_CHAIN" ]
}

@test "_wan_split_nat_chain: pure 10/8 transit is ISP-side, not double-NAT" {
  _wan_split_nat_chain "10.166.41.210 10.166.41.209"
  [ "$WAN_NAT_HOME_COUNT" -eq 0 ]
  [ "$WAN_NAT_ISP_COUNT" -eq 2 ]
  [ "$WAN_NAT_ISP_CHAIN" = "10.166.41.210 → 10.166.41.209" ]
}

@test "_wan_split_nat_chain: mixed chain separates home from ISP transit" {
  _wan_split_nat_chain "192.168.50.1 192.168.1.254 10.166.41.210 10.166.41.209"
  [ "$WAN_NAT_HOME_COUNT" -eq 2 ]
  [ "$WAN_NAT_HOME_CHAIN" = "192.168.50.1 → 192.168.1.254" ]
  [ "$WAN_NAT_ISP_COUNT" -eq 2 ]
  [ "$WAN_NAT_ISP_CHAIN" = "10.166.41.210 → 10.166.41.209" ]
}

@test "_wan_split_nat_chain: 172.16/12 counts as home-side" {
  _wan_split_nat_chain "172.16.0.1 172.31.255.1"
  [ "$WAN_NAT_HOME_COUNT" -eq 2 ]
  [ "$WAN_NAT_ISP_COUNT" -eq 0 ]
}

@test "_wan_split_nat_chain: single home hop → not double-NAT" {
  _wan_split_nat_chain "192.168.1.1"
  [ "$WAN_NAT_HOME_COUNT" -eq 1 ]
}

@test "_wan_split_nat_chain: empty chain → all zero" {
  _wan_split_nat_chain ""
  [ "$WAN_NAT_HOME_COUNT" -eq 0 ]
  [ "$WAN_NAT_ISP_COUNT" -eq 0 ]
  [ -z "$WAN_NAT_HOME_CHAIN" ]
  [ -z "$WAN_NAT_ISP_CHAIN" ]
}

# ── --redact: mask identifying values on stdout ──────────────────────────
# The local log keeps full detail; only what gets shared is masked.

@test "_redact_line: masks public IP, SSID, BSSID and city" {
  PUB_IP="203.0.113.42"; WIFI_SSID="BrianHomeNet"
  WIFI_BSSID="aa:bb:cc:dd:ee:01"; PUB_CITY="Sometown"
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC=""
  result="$(_redact_line "Host BrianHomeNet (203.0.113.42) in Sometown via aa:bb:cc:dd:ee:01")"
  [[ "$result" != *"203.0.113.42"* ]]
  [[ "$result" != *"BrianHomeNet"* ]]
  [[ "$result" != *"Sometown"* ]]
  [[ "$result" != *"aa:bb:cc:dd:ee:01"* ]]
  [[ "$result" == *"[redacted]"* ]]
}

@test "_redact_line: leaves private addresses and ISP name alone" {
  PUB_IP="203.0.113.42"; WIFI_SSID=""; WIFI_BSSID=""; PUB_CITY=""
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC=""
  result="$(_redact_line "Gateway 192.168.1.1 via Example ISP")"
  [ "$result" = "Gateway 192.168.1.1 via Example ISP" ]
}

@test "_redact_line: empty and very short values never match" {
  # An empty secret would otherwise match at every position, and a 1-2 char
  # value would corrupt unrelated text.
  PUB_IP=""; WIFI_SSID=""; WIFI_BSSID=""; PUB_CITY="US"
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC=""
  result="$(_redact_line "Bufferbloat grade A/A · US region · all clear")"
  [ "$result" = "Bufferbloat grade A/A · US region · all clear" ]
}

@test "say: redacts stdout but writes the raw value to the log" {
  tmplog="$BATS_TEST_TMPDIR/x.log"
  LOG="$tmplog"; REDACT=1; JSON_MODE=0; QUIET=0; EXPERT=1; DIAGNOSIS_REACHED=1
  PUB_IP="203.0.113.42"; WIFI_SSID=""; WIFI_BSSID=""; PUB_CITY=""
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC=""
  out="$(say "Public IP: 203.0.113.42")"
  [[ "$out" != *"203.0.113.42"* ]]
  # The on-disk log is the user's own copy and keeps the real value.
  grep -q '203.0.113.42' "$tmplog"
}

# ── Focused runs must not report unmeasured checks as measured ───────────
# --mtu-only and --wifi-only skip most modules, leaving their globals at
# the defaults in globals.sh. Those defaults are indistinguishable from a
# real negative result, so a skipped check was being reported as a failed
# one: --wifi-only exited 2 on a perfectly healthy network.

@test "diagnosis: N1b does not fire when the public check never ran" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  # --wifi-only state: a gateway exists, but public_run never executed, so
  # PUBLIC_OK is still its 0 default and GW_LOSS was never measured.
  GATEWAY="192.168.1.1"; PUBLIC_OK=0; GW_LOSS=""; PUBLIC_CHECKED=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  run diagnosis_run
  [[ "$output" != *"nothing on the public internet responded"* ]]
}

@test "diagnosis: N1b still fires when public was measured and failed" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1"; PUBLIC_OK=0; GW_LOSS=""; PUBLIC_CHECKED=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "diagnosis: N1b message does not name the wrong focus flag" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1"; PUBLIC_OK=0; GW_LOSS=""; PUBLIC_CHECKED=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  run diagnosis_run
  # It used to hardcode "--mtu-only" regardless of which focus was active.
  [[ "$output" != *"without --mtu-only"* ]]
}

@test "headline: link medium is omitted when the WiFi check never ran" {
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
  # --mtu-only state: iface_run ran, wifi_run did not, so IS_WIFI is still 0.
  FOCUS="mtu"; INTERFACE="en0"; IS_WIFI=0; WIFI_CHECKED=0
  run headline_run
  [[ "$output" == *"en0"* ]]
  [[ "$output" != *"wired"* ]]
}

@test "headline: still says wired when the WiFi check ran and found no WiFi" {
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
  FOCUS="mtu"; INTERFACE="en0"; IS_WIFI=0; WIFI_CHECKED=1
  run headline_run
  [[ "$output" == *"wired"* ]]
}

@test "_redact_line: masks the IPv6 link-local gateway" {
  # fe80::…  is EUI-64-derived from the router's MAC, so leaving it in
  # publishes the same gateway MAC that GW_MAC is masked to protect.
  PUB_IP=""; WIFI_SSID=""; WIFI_BSSID=""; PUB_CITY=""
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC="10:98:5f:91:2f:0"
  IPV6_GATEWAY="fe80::1298:5fff:fe91:2f00%en0"
  result="$(_redact_line "System resolver: fe80::1298:5fff:fe91:2f00%en0")"
  [[ "$result" != *"fe91:2f00"* ]]
  [[ "$result" == *"[redacted]"* ]]
}

# ── VPN-1 ────────────────────────────────────────────────────────────────
# docs/DIAGNOSIS-RULES.md has specified VPN-1 since v0.1.0 and the README
# lists it, but lib/vpn.sh only ever printed a section line — no add_diag
# call existed, so an active VPN never reached the Diagnosis section.

@test "diagnosis: VPN-1 fires when a VPN carries the default route" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.2.0.1"
  VPN_ACTIVE=1; VPN_TYPE="tailscale"; VPN_NAME="tailscale (macbook)"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " == *" VPN-1 "* ]]
}

@test "diagnosis: VPN-1 is info severity, so it cannot change the exit code" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.2.0.1"
  VPN_ACTIVE=1; VPN_TYPE="managed"; VPN_NAME="Work VPN"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "VPN-1" ]; then
      [ "${DIAG_SEV[$i]}" = "info" ]
    fi
  done
  [ "$MAX_SEVERITY" -eq 0 ]
}

@test "diagnosis: VPN-1 names the VPN so the user knows which one" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.2.0.1"
  VPN_ACTIVE=1; VPN_TYPE="tailscale"; VPN_NAME="tailscale (macbook)"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  run diagnosis_run
  [[ "$output" == *"tailscale (macbook)"* ]]
}

@test "diagnosis: VPN-1 stays quiet with no VPN" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1"; VPN_ACTIVE=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " != *" VPN-1 "* ]]
}
