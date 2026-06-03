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

@test "_parse_trace_lines: skips '*' (no-reply) hops and renumbers" {
  input='1  192.168.1.1  3.0 ms
2  *
3  10.0.0.1  10.0 ms'
  parsed="$(printf '%s' "$input" | _parse_trace_lines)"
  # Two output lines (the '*' hop is dropped); they're renumbered 1, 2.
  lines="$(printf '%s\n' "$parsed" | grep -c '^[0-9]')"
  [ "$lines" -eq 2 ]
  second_n="$(printf '%s\n' "$parsed" | sed -n '2p' | cut -d'|' -f1)"
  [ "$second_n" = "2" ]
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
