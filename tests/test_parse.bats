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
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
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
  [[ "$output" == *"no network connection at all"* ]] || return 1
  [[ "$output" != *"Nothing obviously wrong"* ]] || return 1

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

# ── bufferbloat_card_verdict (Report card vs. B1/B2) ─────────────────────
#
# The Report card and the diagnosis rules grade the same two numbers, and
# the card used to disagree with them: `*C*` was matched before `*D*|*F*`,
# so a C/F pair printed a yellow "noticeable lag under load" directly above
# B2's red "enough to ruin voice/video calls". These hold the two to one
# table.

@test "bufferbloat card: a D or F on either leg is severe, even beside a C" {
  # The four pairs the old ordering got wrong, and the reason this function
  # exists. Each one has a critical-grade leg, so each must read as severe.
  for pair in CD DC CF FC; do
    result="$(bufferbloat_card_verdict "${pair:0:1}" "${pair:1:1}")"
    [ "${result%%|*}" = "bad" ] || {
      echo "grade pair $pair gave '${result%%|*}', expected bad"
      return 1
    }
  done
}

@test "bufferbloat card: clean pairs stay clean" {
  for pair in AA AB BA BB; do
    result="$(bufferbloat_card_verdict "${pair:0:1}" "${pair:1:1}")"
    [ "${result%%|*}" = "ok" ] || {
      echo "grade pair $pair gave '${result%%|*}', expected ok"
      return 1
    }
  done
}

@test "bufferbloat card: a C with nothing worse is a warning" {
  for pair in AC CA BC CB CC; do
    result="$(bufferbloat_card_verdict "${pair:0:1}" "${pair:1:1}")"
    [ "${result%%|*}" = "warn" ] || {
      echo "grade pair $pair gave '${result%%|*}', expected warn"
      return 1
    }
  done
}

@test "bufferbloat card severity matches B1/B2 for every grade pair" {
  # The real invariant, stated independently of the implementation: B1 and
  # B2 in lib/diagnosis.sh grade each leg on its own (C is warn, D and F are
  # critical) and the worst one owns the verdict. Derive that expectation
  # per leg here and compare, so the card cannot drift from the rules
  # without this failing — for all 25 pairs, not just the four that broke.
  _leg_severity() {
    case "$1" in
      A|B) echo ok ;;
      C)   echo warn ;;
      D|F) echo bad ;;
    esac
  }
  _rank() {
    case "$1" in ok) echo 0 ;; warn) echo 1 ;; bad) echo 2 ;; esac
  }
  for gw in A B C D F; do
    for inet in A B C D F; do
      gw_sev="$(_leg_severity "$gw")"
      inet_sev="$(_leg_severity "$inet")"
      if [ "$(_rank "$gw_sev")" -ge "$(_rank "$inet_sev")" ]; then
        expected="$gw_sev"
      else
        expected="$inet_sev"
      fi
      actual="$(bufferbloat_card_verdict "$gw" "$inet")"
      [ "${actual%%|*}" = "$expected" ] || {
        echo "grade $gw/$inet: card said '${actual%%|*}', B1/B2 imply '$expected'"
        return 1
      }
    done
  done
}

@test "bufferbloat card: an ungraded pair is not silently healthy" {
  # A pair grade_bufferbloat can never produce must not fall through to the
  # green arm and paint an all-clear over a link nobody graded.
  result="$(bufferbloat_card_verdict "" "")"
  [ "${result%%|*}" != "ok" ]
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
  [[ "$first_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
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
  [[ "$MTR_FIRST_LOSSY_HOP" == *"hop 4"* ]] || return 1
  [[ "$MTR_FIRST_LOSSY_HOP" == *"203.0.113.5"* ]] || return 1
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

@test "parse_mtr_tsv: missing loss stays unknown instead of becoming 100%" {
 MTR_FIRST_LOSSY_HOP=""
 parse_mtr_tsv <<'TSV'
1	192.168.1.1
2	10.0.0.1
3	1.1.1.1	0.0	18.0
TSV
  [ -z "$MTR_FIRST_LOSSY_HOP" ]
  [[ "$PER_HOP_LINES" == *"1|192.168.1.1||"* ]] || return 1
}

# ── ARP duplicate detection (inline awk, no library function yet) ────────

@test "ARP parser: arp_dup fixture surfaces 192.168.50.10 as a duplicate" {
  arp_pairs="$(awk '/ at / && $4 != "(incomplete)" {
                      ip = $2; gsub(/[()]/, "", ip); print ip, $4
                    }' "$FIX/arp_dup.txt" | sort -u)"
  duplicates="$(printf '%s\n' "$arp_pairs" | awk '{print $1}' | uniq -d | tr '\n' ' ')"
  [[ "$duplicates" == *"192.168.50.10"* ]] || return 1
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
  [[ "$chain" == "192.168.50.1 192.168.1.254 10.166.41.210 10.166.41.209" ]] || return 1
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
  [[ "$result" != *"203.0.113.42"* ]] || return 1
  [[ "$result" != *"BrianHomeNet"* ]] || return 1
  [[ "$result" != *"Sometown"* ]] || return 1
  [[ "$result" != *"aa:bb:cc:dd:ee:01"* ]] || return 1
  [[ "$result" == *"[redacted]"* ]] || return 1
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
  [[ "$out" != *"203.0.113.42"* ]] || return 1
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
  [[ "$output" != *"nothing on the public internet responded"* ]] || return 1
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
  [[ "$output" != *"without --mtu-only"* ]] || return 1
}

@test "headline: link medium is omitted when the WiFi check never ran" {
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
  # --mtu-only state: iface_run ran, wifi_run did not, so IS_WIFI is still 0.
  FOCUS="mtu"; INTERFACE="en0"; IS_WIFI=0; WIFI_CHECKED=0
  run headline_run
  [[ "$output" == *"en0"* ]] || return 1
  [[ "$output" != *"wired"* ]] || return 1
}

@test "headline: still says wired when the WiFi check ran and found no WiFi" {
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
  FOCUS="mtu"; INTERFACE="en0"; IS_WIFI=0; WIFI_CHECKED=1
  run headline_run
  [[ "$output" == *"wired"* ]] || return 1
}

@test "_redact_line: masks the IPv6 link-local gateway" {
  # fe80::…  is EUI-64-derived from the router's MAC, so leaving it in
  # publishes the same gateway MAC that GW_MAC is masked to protect.
  PUB_IP=""; WIFI_SSID=""; WIFI_BSSID=""; PUB_CITY=""
  LOCAL_IP=""; IPV6_GLOBAL_ADDR=""; GW_MAC="10:98:5f:91:2f:0"
  IPV6_GATEWAY="fe80::1298:5fff:fe91:2f00%en0"
  result="$(_redact_line "System resolver: fe80::1298:5fff:fe91:2f00%en0")"
  [[ "$result" != *"fe91:2f00"* ]] || return 1
  [[ "$result" == *"[redacted]"* ]] || return 1
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
  [[ " ${DIAG_RULE[*]:-} " == *" VPN-1 "* ]] || return 1
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
  [[ "$output" == *"tailscale (macbook)"* ]] || return 1
}

@test "diagnosis: VPN-1 stays quiet with no VPN" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1"; VPN_ACTIVE=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " != *" VPN-1 "* ]] || return 1
}


# ── Assertion helpers ────────────────────────────────────────────────────
# A failing `[[ ... ]]` does NOT abort a bats test on bats-core 1.14 —
# bash does not run the ERR trap bats installs for conditional constructs,
# so any `[[ ]]` that isn't the last statement in a test body is silently
# a no-op. A failing *function call* does abort, so assertions that must
# actually hold go through these.
#
# Verified with a two-line probe: `[[ " P1 " == *" CP-1 "* ]]` followed by
# `[ 1 -eq 1 ]` reports ok; the same test with `[ ]` reports not ok.

assert_contains() {
  case "$1" in (*"$2"*) return 0 ;; esac
  echo "expected to contain: [$2]" >&2
  echo "actual:              [$1]" >&2
  return 1
}

assert_not_contains() {
  case "$1" in (*"$2"*)
    echo "expected NOT to contain: [$2]" >&2
    echo "actual:                  [$1]" >&2
    return 1 ;;
  esac
  return 0
}

# ── N1c: joined, addressed, no route out ─────────────────────────────────
# N1 originally fired on the missing route alone and told the user their
# Mac "isn't joined to a WiFi network" — a claim nothing in the run had
# checked, and one the same report contradicted three lines higher by
# printing the SSID and the signal strength.

@test "diagnosis: joined with no route is N1c, and does not claim WiFi is off" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=1 WIFI_SSID="Mercure" WIFI_RSSI=-44
  LINK_DHCP_ROUTER="10.125.128.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1c" ]
  [ "$MAX_SEVERITY" -eq 2 ]
  assert_contains "${DIAG[0]}" "Mercure"
  assert_contains "${DIAG[0]}" "10.125.128.1"
  assert_not_contains "${DIAG[0]}" "isn't joined to a WiFi network"
}

@test "diagnosis: joined with no route on ethernet names no SSID" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=0 LINK_DHCP_ROUTER="192.168.1.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1c" ]
  assert_contains "${DIAG[0]}" "192.168.1.1"
  assert_contains "${DIAG[0]}" "ethernet cable is connected"
}

@test "diagnosis: nothing joined is still N1, not N1c" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1" ]
  [ "$MAX_SEVERITY" -eq 2 ]
}

# ── WI-1: macOS is withholding the network's name ────────────────────────
#
# A data-completeness rule. Three real flapping episodes in this project's
# own history (112, 241 and 173 disassociations in an hour) cannot be
# confirmed to have been on the same network, because all three are filed
# under "WiFi (SSID hidden by macOS)".

@test "diagnosis: a hidden SSID fires WI-1 as info" {
  sp_setup
  WIFI_NAME_HIDDEN=1
  diagnosis_run >/dev/null
  diag_has WI-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "WI-1 moved the exit code"; return 1; }
  assert_contains "$(diag_text_for WI-1)" "Location Services"
}

@test "diagnosis: WI-1 explains the consequence, not just the permission" {
  # The point is not "grant a permission"; it is that history for this
  # network merges with every other unnamed one.
  sp_setup
  WIFI_NAME_HIDDEN=1
  diagnosis_run >/dev/null
  assert_contains "$(diag_text_for WI-1)" "history"
  # And it says so without implying a fault: the rule reports a gap in
  # what netdiag can record, not a problem with the network.
  assert_contains "$(diag_text_for WI-1)" "Nothing is broken"
}

@test "diagnosis: a named network does not fire WI-1" {
  sp_setup
  WIFI_NAME_HIDDEN=0 WIFI_SSID="Home"
  diagnosis_run >/dev/null
  diag_has WI-1 && { echo "WI-1 fired on a named network"; return 1; }
  return 0
}

@test "diagnosis: WI-1 is a WiFi rule and never fires on ethernet" {
  sp_setup
  IS_WIFI=0 WIFI_NAME_HIDDEN=1
  diagnosis_run >/dev/null
  diag_has WI-1 && { echo "WI-1 fired on a wired link"; return 1; }
  return 0
}

# ── MET-1: this connection costs money by the megabyte ───────────────────

@test "diagnosis: a metered link fires MET-1 as info" {
  sp_setup
  LINK_METERED=1 LINK_METERED_CERTAIN=1 LINK_SERVICE="iPhone USB"
  diagnosis_run >/dev/null
  diag_has MET-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "MET-1 moved the exit code"; return 1; }
  assert_contains "$(diag_text_for MET-1)" "iPhone USB"
  assert_contains "$(diag_text_for MET-1)" "--speed"
}

@test "diagnosis: MET-1 warns that router advice does not apply" {
  # The point of firing it even when the speed test was skipped: every
  # other recommendation in the report is wrong on a tethered link.
  sp_setup
  LINK_METERED=1 LINK_METERED_CERTAIN=1 LINK_SERVICE="iPhone USB"
  diagnosis_run >/dev/null
  assert_contains "$(diag_text_for MET-1)" "routers and cables"
}

@test "diagnosis: an ordinary link does not fire MET-1" {
  sp_setup
  LINK_METERED=0 LINK_SERVICE="Wi-Fi" LINK_METERED_CERTAIN=0
  PATH_SPLIT_TUNNEL=0 PATH_SPLIT_TUNNEL_IFACES=""
  PATH_PROXY=0 PATH_PROXY_DETAIL="" PATH_FILTERS="" PATH_FILTER_COUNT=0
  NETWORK_CHANGED_MID_RUN=0
  diagnosis_run >/dev/null
  diag_has MET-1 && { echo "MET-1 fired on an unmetered link"; return 1; }
  return 0
}

@test "diagnosis: MET-1 still names the link with no service name" {
  sp_setup
  LINK_METERED=1 LINK_METERED_CERTAIN=1 LINK_SERVICE=""
  diagnosis_run >/dev/null
  diag_has MET-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for MET-1)" "tethered device"
}

@test "diagnosis: an inferred metered link hedges instead of asserting" {
  # 192.168.43.0/24 is the Android hotspot default AND a range an
  # ordinary home network could use. Telling that user "You're online
  # through a phone" would be a confidently wrong claim about their own
  # network — the exact failure this whole batch of work is about.
  sp_setup
  LINK_METERED=1 LINK_METERED_CERTAIN=0 LINK_SERVICE="Wi-Fi"
  LINK_IP="192.168.43.10"
  diagnosis_run >/dev/null
  diag_has MET-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  local t; t="$(diag_text_for MET-1)"
  assert_not_contains "$t" "You're online through"
  assert_contains "$t" "192.168.43.10"
  # It must offer the way out, and say plainly that nothing is wrong if
  # the guess was wrong.
  assert_contains "$t" "--speed"
  assert_contains "$t" "home or office network"
}

@test "diagnosis: the certain and inferred wordings are mutually exclusive" {
  sp_setup
  LINK_METERED=1 LINK_METERED_CERTAIN=1 LINK_SERVICE="iPhone USB"
  diagnosis_run >/dev/null
  assert_not_contains "$(diag_text_for MET-1)" "range phones use"
}

# ── pct_at_least: the arithmetic SP-1 rests on ───────────────────────────

@test "pct_at_least: 58% of the PHY rate clears a 45% cutoff" {
  # A gigabit plan over a 130 Mb/s link measures about 75.
  run pct_at_least 75 130 45
  [ "$status" -eq 0 ]
}

@test "pct_at_least: 38% does not clear it" {
  # A 50 Mb/s plan over the same link. The user's ISP really is the cap.
  run pct_at_least 50 130 45
  [ "$status" -ne 0 ]
}

@test "pct_at_least: exactly the cutoff counts as reaching it" {
  run pct_at_least 45 100 45
  [ "$status" -eq 0 ]
}

@test "pct_at_least: an unmeasured value never satisfies the comparison" {
  run pct_at_least "" 130 45
  [ "$status" -ne 0 ]
  run pct_at_least 75 "" 45
  [ "$status" -ne 0 ]
  run pct_at_least 75 130 ""
  [ "$status" -ne 0 ]
}

@test "pct_at_least: a zero or negative total is refused, not divided by" {
  run pct_at_least 75 0 45
  [ "$status" -ne 0 ]
  run pct_at_least 75 -10 45
  [ "$status" -ne 0 ]
}

@test "pct_at_least: floats on either side compare numerically" {
  run pct_at_least 94.32 130.5 45
  [ "$status" -eq 0 ]
  run pct_at_least 9.4 130.5 45
  [ "$status" -ne 0 ]
}

@test "pct_at_least: a non-numeric value is refused rather than string-compared" {
  # The failure this guards: awk silently degrades to a string compare
  # and produces a confidently wrong answer.
  run pct_at_least "fast" 130 45
  [ "$status" -ne 0 ]
}

# ── SP-1: the wireless link is the cap, not the plan ─────────────────────

sp_setup() {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  GATEWAY="192.168.1.1" LINK_UP=1 IS_WIFI=1 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS="" WIFI_RSSI="" WIFI_SNR="" WIFI_SSID="Home"
  WIFI_TX="" SPEEDTEST_DOWN_MBPS=""
  LINK_MEDIA_MBPS="" LINK_MEDIA_MAX_MBPS="" LINK_DUPLEX=""
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=0
  LINK_METERED=0 LINK_SERVICE="Wi-Fi" LINK_METERED_CERTAIN=0
  PATH_SPLIT_TUNNEL=0 PATH_SPLIT_TUNNEL_IFACES=""
  PATH_PROXY=0 PATH_PROXY_DETAIL="" PATH_FILTERS="" PATH_FILTER_COUNT=0
  NETWORK_CHANGED_MID_RUN=0
  WIFI_NAME_HIDDEN=0 WIFI_PRIVILEGED=0 WIFI_DISCONNECT_COUNT=0
  EXPERT=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

@test "diagnosis: a download at the WiFi ceiling fires SP-1 as info" {
  sp_setup
  WIFI_TX=130 SPEEDTEST_DOWN_MBPS=75
  diagnosis_run >/dev/null
  diag_has SP-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  # info must not move the exit code — nothing here is broken.
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "MAX_SEVERITY=$MAX_SEVERITY"; return 1; }
  assert_contains "$(diag_text_for SP-1)" "130"
  assert_contains "$(diag_text_for SP-1)" "75"
  assert_contains "$(diag_text_for SP-1)" "ethernet"
}

@test "diagnosis: a genuinely slow plan is not blamed on the WiFi" {
  # 50 of a possible 130 is 38%. The link has headroom; the ISP is the
  # cap. Claiming otherwise sends the user to buy a router they don't need.
  sp_setup
  WIFI_TX=130 SPEEDTEST_DOWN_MBPS=50
  diagnosis_run >/dev/null
  diag_has SP-1 && { echo "SP-1 fired with 92 Mbps of headroom"; return 1; }
  return 0
}

@test "diagnosis: SP-1 cannot fire without the privileged tx rate" {
  # WIFI_TX needs sudo. Guessing an explanation is worse than none.
  sp_setup
  WIFI_TX="" SPEEDTEST_DOWN_MBPS=75
  diagnosis_run >/dev/null
  diag_has SP-1 && { echo "SP-1 fired without a PHY rate"; return 1; }
  return 0
}

@test "diagnosis: SP-1 stays quiet when no speed test ran" {
  sp_setup
  WIFI_TX=130 SPEEDTEST_DOWN_MBPS=""
  diagnosis_run >/dev/null
  diag_has SP-1 && { echo "SP-1 fired with no speed result"; return 1; }
  return 0
}

@test "diagnosis: SP-1 is a WiFi rule and never fires on ethernet" {
  sp_setup
  IS_WIFI=0 WIFI_TX=130 SPEEDTEST_DOWN_MBPS=75
  diagnosis_run >/dev/null
  diag_has SP-1 && { echo "SP-1 fired on a wired link"; return 1; }
  return 0
}

# ── ETH-1 / ETH-2: the wired link negotiated badly ───────────────────────
# A 10x cap invisible everywhere but one line of ifconfig, which the speed
# test then reports as a slow ISP.

eth_setup() {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="192.168.1.1" LINK_UP=1 IS_WIFI=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS="" WIFI_RSSI="" WIFI_SNR=""
  LINK_MEDIA_MBPS="" LINK_MEDIA_MAX_MBPS="" LINK_DUPLEX=""
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=0
  LINK_METERED=0 LINK_SERVICE="Wi-Fi" LINK_METERED_CERTAIN=0
  PATH_SPLIT_TUNNEL=0 PATH_SPLIT_TUNNEL_IFACES=""
  PATH_PROXY=0 PATH_PROXY_DETAIL="" PATH_FILTERS="" PATH_FILTER_COUNT=0
  NETWORK_CHANGED_MID_RUN=0
  WIFI_NAME_HIDDEN=0 WIFI_PRIVILEGED=0 WIFI_DISCONNECT_COUNT=0
  EXPERT=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

diag_has() {
  local want="$1" r
  for r in "${DIAG_RULE[@]}"; do [ "$r" = "$want" ] && return 0; done
  return 1
}

diag_text_for() {
  local want="$1" i=0
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "$want" ] && { printf '%s' "${DIAG[$i]}"; return 0; }
  done
  return 1
}

@test "diagnosis: a gigabit port at 100 Mb/s fires ETH-1" {
  eth_setup
  LINK_MEDIA_MBPS=100 LINK_MEDIA_MAX_MBPS=1000 LINK_DUPLEX=full
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  diagnosis_run >/dev/null
  diag_has ETH-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for ETH-1)" "100 Mb/s"
  assert_contains "$(diag_text_for ETH-1)" "1000 Mb/s"
  assert_contains "$(diag_text_for ETH-1)" "cable"
}

@test "diagnosis: a link at the port's full speed fires nothing" {
  eth_setup
  LINK_MEDIA_MBPS=1000 LINK_MEDIA_MAX_MBPS=1000 LINK_DUPLEX=full
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  diagnosis_run >/dev/null
  diag_has ETH-1 && { echo "ETH-1 fired on a healthy gigabit link"; return 1; }
  diag_has ETH-2 && { echo "ETH-2 fired on a full-duplex link"; return 1; }
  return 0
}

@test "diagnosis: a 100 Mb/s-only adapter is not accused of being slow" {
  # The number is the truth on this port, not a fault. This is why the
  # rule compares two measured values instead of testing a cutoff.
  eth_setup
  LINK_MEDIA_MBPS=100 LINK_MEDIA_MAX_MBPS=100 LINK_DUPLEX=full
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  diagnosis_run >/dev/null
  diag_has ETH-1 && { echo "ETH-1 fired on a port doing its maximum"; return 1; }
  return 0
}

@test "diagnosis: half duplex on a full-duplex-capable port fires ETH-2" {
  eth_setup
  LINK_MEDIA_MBPS=10 LINK_MEDIA_MAX_MBPS=1000 LINK_DUPLEX=half
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  diagnosis_run >/dev/null
  diag_has ETH-2 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 2 ]
  assert_contains "$(diag_text_for ETH-2)" "half-duplex"
}

@test "diagnosis: half duplex on a half-duplex-only port stays quiet" {
  # An old adapter that only ever does half duplex is not a fault, and
  # saying so would be noise.
  eth_setup
  LINK_MEDIA_MBPS=10 LINK_MEDIA_MAX_MBPS=10 LINK_DUPLEX=half
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=0
  diagnosis_run >/dev/null
  diag_has ETH-2 && { echo "ETH-2 fired on a port with no full-duplex mode"; return 1; }
  return 0
}

@test "diagnosis: WiFi never fires an ethernet rule" {
  # Wi-Fi reports no media subtype, so LINK_MEDIA_MBPS is empty. A rate
  # invented for it would fire ETH-1 on every wireless run.
  eth_setup
  IS_WIFI=1 WIFI_SSID="Home"
  LINK_MEDIA_MBPS="" LINK_MEDIA_MAX_MBPS="" LINK_DUPLEX=""
  diagnosis_run >/dev/null
  diag_has ETH-1 && { echo "ETH-1 fired on WiFi"; return 1; }
  diag_has ETH-2 && { echo "ETH-2 fired on WiFi"; return 1; }
  return 0
}

@test "diagnosis: with ETH-2 firing, G2 stops telling users to reboot the router" {
  # Collisions on a half-duplex link produce heavy gateway loss. G2's
  # headline advice would send the user to power-cycle a box that works.
  eth_setup
  . "$REPO/lib/thresholds.sh"
  LINK_MEDIA_MBPS=10 LINK_MEDIA_MAX_MBPS=1000 LINK_DUPLEX=half
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  GW_LOSS=40
  diagnosis_run >/dev/null
  diag_has G2 || { echo "G2 did not fire; rules: ${DIAG_RULE[*]}"; return 1; }
  assert_not_contains "$(diag_text_for G2)" "rebooting the router"
  assert_contains "$(diag_text_for G2)" "half-duplex"
}

@test "diagnosis: without ETH-2, G2 keeps its original advice" {
  eth_setup
  . "$REPO/lib/thresholds.sh"
  GW_LOSS=40
  diagnosis_run >/dev/null
  diag_has G2 || { echo "G2 did not fire; rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for G2)" "rebooting the router"
}

@test "diagnosis: with ETH-2 firing, G3 blames the negotiation" {
  eth_setup
  . "$REPO/lib/thresholds.sh"
  LINK_MEDIA_MBPS=10 LINK_MEDIA_MAX_MBPS=1000 LINK_DUPLEX=half
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=1
  GW_LOSS=10
  diagnosis_run >/dev/null
  diag_has G3 || { echo "G3 did not fire; rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for G3)" "half-duplex"
  assert_not_contains "$(diag_text_for G3)" "reseating or swapping the cable"
}

# ── DH-3: joined, but nothing handed out an address ──────────────────────
# The third state N1 used to swallow. A Mac associated at full signal with
# a 169.254 self-assigned address was told it "has no network connection
# at all — nothing is joined", which is both false and a different fix.

@test "diagnosis: a self-assigned address is DH-3, not N1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=0 LINK_SELF_ASSIGNED=1 LINK_IP="169.254.211.7"
  IS_WIFI=1 WIFI_SSID="Mercure"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "DH-3" ] || { echo "fired ${DIAG_RULE[0]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 2 ]
  assert_contains "${DIAG[0]}" "Mercure"
  assert_contains "${DIAG[0]}" "169.254.211.7"
  assert_not_contains "${DIAG[0]}" "no network connection at all"
}

@test "diagnosis: DH-3 on ethernet talks about the cable, not WiFi" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=0 LINK_SELF_ASSIGNED=1 LINK_IP="169.254.9.9" IS_WIFI=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "DH-3" ] || { echo "fired ${DIAG_RULE[0]}"; return 1; }
  assert_contains "${DIAG[0]}" "ethernet cable"
  assert_not_contains "${DIAG[0]}" "WiFi off and on"
}

@test "diagnosis: DH-3 does not displace N1c when there is a real lease" {
  # A real lease with no route is still the captive-portal case. DH-3 must
  # not steal it just because both lack a gateway.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 LINK_SELF_ASSIGNED=0 IS_WIFI=1 WIFI_SSID="Mercure"
  LINK_DHCP_ROUTER="10.125.128.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1c" ] || { echo "fired ${DIAG_RULE[0]}"; return 1; }
}

@test "diagnosis: DH-3, N1c and N1 are mutually exclusive" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  local seen
  for state in "1 0" "0 1" "0 0"; do
    # shellcheck disable=SC2086
    set -- $state
    GATEWAY="" LINK_UP="$1" LINK_SELF_ASSIGNED="$2" IS_WIFI=1
    LINK_IP="169.254.1.1"
    DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
    diagnosis_run >/dev/null
    seen=0
    for r in "${DIAG_RULE[@]}"; do
      case "$r" in N1|N1c|DH-3) seen=$((seen + 1)) ;; esac
    done
    [ "$seen" -eq 1 ] || { echo "LINK_UP=$1 LINK_SELF_ASSIGNED=$2 fired $seen of the three"; return 1; }
  done
}

@test "diagnosis: N1c and N1 are mutually exclusive" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=1 WIFI_SSID="Mercure"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_not_contains " ${DIAG_RULE[*]} " " N1 "
  assert_contains " ${DIAG_RULE[*]} " " N1c "
}

@test "diagnosis: N1c does not name a router it was never offered" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=1 WIFI_SSID="Mercure" LINK_DHCP_ROUTER=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_not_contains "${DIAG[0]}" "http://"
  assert_contains "${DIAG[0]}" "ask the network's owner"
}

# ── CP-1: a portal is a diagnosis, not just a log line ───────────────────
# lib/public.sh has set CAPTIVE_PORTAL since v0.1 and printed a warn line
# about it, but never called add_diag — so the portal never reached
# status.rules[], the GUI's "What we found", or the exit code. P1 fired
# instead, telling the user on a hotel network to "check their ISP's
# status page or call support".

@test "diagnosis: a portal blocking the internet is a critical CP-1, not P1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_contains " ${DIAG_RULE[*]} " " CP-1 "
  assert_not_contains " ${DIAG_RULE[*]} " " P1 "
  assert_not_contains " ${DIAG_RULE[*]} " " P2 "
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "diagnosis: a portal that still lets traffic through is a warning" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=1
  CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_contains " ${DIAG_RULE[*]} " " CP-1 "
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "diagnosis: no portal leaves P1 in charge" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  CAPTIVE_PORTAL=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_contains " ${DIAG_RULE[*]} " " P1 "
  assert_not_contains " ${DIAG_RULE[*]} " " CP-1 "
}

# ── D2: total resolver failure ───────────────────────────────────────────
# D1 requires PUBLIC_OK=1, so on a network with no internet the DNS check
# could measure "0 of 6 resolvers OK" and fire nothing at all — which the
# GUI, which colors that row from rules, rendered as a green dot beside
# the words "0 of 6 resolvers OK".

@test "diagnosis: every resolver failing fires D2 even with no internet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL
8.8.8.8|apple.com||FAIL"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_contains " ${DIAG_RULE[*]} " " D2 "
}

@test "diagnosis: D2 does not fire when the DNS check never ran" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=0 DNS_LINES=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_not_contains " ${DIAG_RULE[*]} " " D2 "
}

@test "diagnosis: D2 and D1 do not both fire" {
  # D1 is the partial case (internet up, some lookups failing); D2 is the
  # total one. Both firing would put two DNS verdicts in one report.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  assert_contains " ${DIAG_RULE[*]} " " D1 "
  assert_not_contains " ${DIAG_RULE[*]} " " D2 "
}

# ── DQ-1: the run measured two networks, not one ─────────────────────────
#
# A full check takes ~60 s. Walk out of WiFi range onto ethernet at second
# 30 and the run blends two networks, then files the blend under one of
# them — where BL-1 judges every future run against a baseline that
# describes a transition.

@test "diagnosis: a network change mid-run fires DQ-1 as info" {
  sp_setup
  NETWORK_CHANGED_MID_RUN=1
  diagnosis_run >/dev/null
  diag_has DQ-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "DQ-1 moved the exit code"; return 1; }
  assert_contains "$(diag_text_for DQ-1)" "changed networks"
  # It must say the run was kept out of history, or the user has no way
  # to know why the result is missing from their trends.
  assert_contains "$(diag_text_for DQ-1)" "left out of the history"
}

@test "diagnosis: a stable run does not fire DQ-1" {
  sp_setup
  NETWORK_CHANGED_MID_RUN=0
  diagnosis_run >/dev/null
  diag_has DQ-1 && { echo "DQ-1 fired on a stable run"; return 1; }
  return 0
}

@test "diagnosis: DQ-1 quotes no network identity" {
  # The fingerprint carries the SSID and BSSID of both networks. Naming
  # either would put a second network's identity into a report filed
  # under the first — and into anything the user pastes.
  sp_setup
  NETWORK_CHANGED_MID_RUN=1 WIFI_SSID="Mercure"
  diagnosis_run >/dev/null
  assert_not_contains "$(diag_text_for DQ-1)" "Mercure"
}

# ── VPN-2 / PX-1 / FW-1: something else is in the path ───────────────────
#
# One assumption wearing three disguises: netdiag equates "carries my
# traffic" with "holds the default route". Each of these sits in the
# datapath without taking it, so every measurement above still reads as a
# clean description of "the network".

@test "diagnosis: a split tunnel fires VPN-2 as info" {
  sp_setup
  PATH_SPLIT_TUNNEL=1 PATH_SPLIT_TUNNEL_IFACES="utun4"
  diagnosis_run >/dev/null
  diag_has VPN-2 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "VPN-2 moved the exit code"; return 1; }
  assert_contains "$(diag_text_for VPN-2)" "utun4"
  # The load-bearing sentence: this report did not measure the tunnel.
  assert_contains "$(diag_text_for VPN-2)" "direct path"
}

@test "diagnosis: a proxy fires PX-1 and names it" {
  sp_setup
  PATH_PROXY=1 PATH_PROXY_DETAIL="proxy.corp.example:8080"
  diagnosis_run >/dev/null
  diag_has PX-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for PX-1)" "proxy.corp.example:8080"
  assert_contains "$(diag_text_for PX-1)" "connect directly"
}

@test "diagnosis: a content filter fires FW-1 without accusing it" {
  # These are usually working exactly as their owner intended. A network
  # tool crying wolf about corporate security software is worse than
  # silence, so the wording must stay descriptive.
  sp_setup
  PATH_FILTER_COUNT=1 PATH_FILTERS="com.netskope.client.NetskopeClientExtension"
  diagnosis_run >/dev/null
  diag_has FW-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for FW-1)" "com.netskope.client.NetskopeClientExtension"
  assert_contains "$(diag_text_for FW-1)" "not a fault in itself"
}

@test "diagnosis: a clean path fires none of the three" {
  sp_setup
  diagnosis_run >/dev/null
  for r in VPN-2 PX-1 FW-1; do
    diag_has "$r" && { echo "$r fired on a clean path"; return 1; }
  done
  return 0
}

@test "diagnosis: the path rules never move the exit code" {
  # All three are info by design. A split tunnel is not a fault, and
  # exiting 1 or 2 on one would make every corporate Mac look broken.
  sp_setup
  PATH_SPLIT_TUNNEL=1 PATH_SPLIT_TUNNEL_IFACES="utun4"
  PATH_PROXY=1 PATH_PROXY_DETAIL="p:1"
  PATH_FILTER_COUNT=1 PATH_FILTERS="com.example.f"
  diagnosis_run >/dev/null
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "MAX_SEVERITY=$MAX_SEVERITY"; return 1; }
}

# ── V6-3: the network is IPv6-only, by design ────────────────────────────
#
# netdiag's GATEWAY comes from `route -n get default`, which is IPv4. So
# an IPv6-only network left it empty and fell into N1c or N1 — critical,
# exit 2, and false on a network working exactly as intended.

v6_setup() {
  # shellcheck source=../lib/ipv6.sh
  . "$REPO/lib/ipv6.sh"
  sp_setup
  IPV6_ONLY=0 IPV6_CLAT=0
}

@test "ipv6: the 464XLAT range is recognised, and only that range" {
  # RFC 7335 reserves 192.0.0.0/29 for the IPv4 side of a translator.
  # 192.0.0.8 and up are other IETF protocol assignments.
  . "$REPO/lib/ipv6.sh"
  for ip in 192.0.0.0 192.0.0.1 192.0.0.4 192.0.0.7; do
    ipv6_is_clat_address "$ip" || { echo "$ip not recognised"; return 1; }
  done
  for ip in 192.0.0.8 192.0.0.10 192.0.2.1 192.168.0.1 "" 192.0.0.71; do
    ipv6_is_clat_address "$ip" && { echo "$ip wrongly recognised"; return 1; }
  done
  return 0
}

@test "ipv6: v6-only needs IPv6 proven, not merely present" {
  # V6-1 exists because a half-configured IPv6 stack is common. A global
  # address alone must not suppress a genuine outage.
  . "$REPO/lib/ipv6.sh"
  #                available aaaa tcp gateway
  ipv6_is_v6_only  1 1 1 ""     || { echo "fully working v6, no v4: should be v6-only"; return 1; }
  ipv6_is_v6_only  1 0 1 ""     && { echo "AAAA failing counted as v6-only"; return 1; }
  ipv6_is_v6_only  1 1 0 ""     && { echo "TCP6 failing counted as v6-only"; return 1; }
  ipv6_is_v6_only  0 1 1 ""     && { echo "no v6 at all counted as v6-only"; return 1; }
  ipv6_is_v6_only  1 1 1 "192.168.1.1" && { echo "a working v4 gateway counted as v6-only"; return 1; }
  return 0
}

@test "diagnosis: an IPv6-only network is V6-3, not N1 or N1c" {
  # The load-bearing test. Before V6-3 this exact state exited 2.
  v6_setup
  # The consistent state: IPV6_ONLY is only ever 1 when AAAA and TCP6
  # both worked, so the fixture has to say so too.
  GATEWAY="" LINK_UP=1 IPV6_ONLY=1 IPV6_AVAILABLE=1
  IPV6_AAAA_OK=1 IPV6_TCP_OK=1 IPV6_PING_LOSS=0
  diagnosis_run >/dev/null
  diag_has V6-3 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  diag_has N1   && { echo "N1 fired on a healthy IPv6-only network"; return 1; }
  diag_has N1c  && { echo "N1c fired on a healthy IPv6-only network"; return 1; }
  # V6-1 would contradict V6-3 outright, and could still fire on ping
  # loss alone since IPV6_ONLY already requires AAAA and TCP6 to work.
  diag_has V6-1 && { echo "V6-1 contradicted V6-3"; return 1; }
  [ "$MAX_SEVERITY" -eq 0 ] || { echo "MAX_SEVERITY=$MAX_SEVERITY — would exit non-zero"; return 1; }
  return 0
}

@test "diagnosis: V6-3 mentions the translation only when it is set up" {
  v6_setup
  GATEWAY="" IPV6_ONLY=1 IPV6_CLAT=1
  diagnosis_run >/dev/null
  assert_contains "$(diag_text_for V6-3)" "translation"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  IPV6_CLAT=0
  diagnosis_run >/dev/null
  assert_not_contains "$(diag_text_for V6-3)" "translation"
}

@test "diagnosis: V6-1 never contradicts V6-3 on a lossy v6-only link" {
  # ICMP6 filtered while TCP works: the same false alarm ICMP-1 exists
  # to prevent on the v4 side. Printing "your IPv6 is half-broken"
  # directly above "IPv6-only and everything checked out" is worse than
  # printing neither.
  v6_setup
  GATEWAY="" LINK_UP=1 IPV6_ONLY=1 IPV6_AVAILABLE=1
  IPV6_AAAA_OK=1 IPV6_TCP_OK=1 IPV6_PING_LOSS=100
  diagnosis_run >/dev/null
  diag_has V6-3 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  diag_has V6-1 && { echo "V6-1 fired alongside V6-3"; return 1; }
  return 0
}

@test "diagnosis: V6-1 still fires on a dual-stack network with broken v6" {
  # The guard must not disable V6-1 generally — that is the case it was
  # written for.
  v6_setup
  GATEWAY="192.168.1.1" IPV6_ONLY=0 IPV6_AVAILABLE=1
  IPV6_AAAA_OK=0 IPV6_TCP_OK=0 IPV6_PING_LOSS=100 PUBLIC_OK=1
  diagnosis_run >/dev/null
  diag_has V6-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  return 0
}

@test "diagnosis: a real outage still fires N1, not V6-3" {
  # IPV6_ONLY is 0 whenever IPv6 was not proven, so nothing is
  # suppressed on a genuinely dead network.
  v6_setup
  GATEWAY="" LINK_UP=0 IPV6_ONLY=0
  diagnosis_run >/dev/null
  diag_has N1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  diag_has V6-3 && { echo "V6-3 fired on a dead network"; return 1; }
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "diagnosis: a captive portal still fires N1c, not V6-3" {
  v6_setup
  GATEWAY="" LINK_UP=1 IPV6_ONLY=0 LINK_DHCP_ROUTER="10.0.0.1"
  diagnosis_run >/dev/null
  diag_has N1c || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  diag_has V6-3 && { echo "V6-3 stole the portal case"; return 1; }
  return 0
}
