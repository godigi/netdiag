#!/usr/bin/env bats
#
# Packet-loss diagnosis rules (L1, L2, G3) and the P1/P2 threshold
# amendment they forced.
#
# The gap these close: netdiag measured internet-side loss into INET_LOSS
# and coloured a Report-card row with it, but no diagnosis rule ever read
# the variable. Since only add_diag moves MAX_SEVERITY (ok/warn/bad are
# pure printers), 40% loss to the internet with a clean gateway produced
# "Nothing obviously wrong — your network looks healthy" and exit 0 — on
# a link that stalls every page load. P1/P2 couldn't cover it because
# they require public.ok == false, and curl still succeeds under heavy
# loss; it just takes several retransmits to do it.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  # thresholds.sh declares the cutoffs diagnosis.sh fires on; bin/netdiag
  # sources it before common.sh and so must every test that exercises a rule.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
}

# A network that is healthy in every respect the other rules test, so any
# diagnosis that fires below is attributable to the loss numbers alone.
healthy_baseline() {
  GATEWAY=192.168.1.1
  GW_LOSS=0 GW_LATENCY=3.1 GW_JITTER=0.4
  PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_OK=1 DNS_LINES="1.1.1.1 ok"
  INET_LOSS=0 INET_LOSS_ALT=0
  IS_WIFI=0
  TCP_REACH_ANY_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

fired()     { [[ " ${DIAG_RULE[*]:-} " == *" $1 "* ]]; }
not_fired() { [[ " ${DIAG_RULE[*]:-} " != *" $1 "* ]]; }

# Severity recorded for a given rule, so a test can assert critical-vs-warn
# rather than merely "something fired".
sev_of() {
  local i
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "$1" ] && { printf '%s' "${DIAG_SEV[$i]}"; return 0; }
  done
  return 1
}

# ── The bug itself ───────────────────────────────────────────────────────

@test "L1: severe internet-side loss with a clean gateway is a critical" {
  healthy_baseline
  INET_LOSS=40 INET_LOSS_ALT=35
  TCP_REACH_ANY_OK=1
  diagnosis_run >/dev/null
  fired L1
  [ "$(sev_of L1)" = critical ]
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "L1: the pre-fix scenario no longer reports a healthy network" {
  # Exactly the shape that exited 0: public reachable, DNS fine, gateway
  # clean, 40% loss upstream.
  healthy_baseline
  INET_LOSS=40 INET_LOSS_ALT=40
  run diagnosis_run
  [[ "$output" != *"Nothing obviously wrong"* ]]
}

# ── False-positive guards ────────────────────────────────────────────────

@test "L1 does not fire when only one target is lossy (anycast rate-limit)" {
  # 1.1.1.1 rate-limits ICMP under load. One lossy target and one clean
  # one is a measurement artefact, not an outage — warn, never critical.
  healthy_baseline
  INET_LOSS=40 INET_LOSS_ALT=0
  diagnosis_run >/dev/null
  not_fired L1
  fired L2
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "L1 does not fire when the gateway is also lossy" {
  # Loss present at the router too means the problem is the LAN/WiFi link.
  # G1/G2 owns that diagnosis; L1 would double-report it as an ISP fault.
  healthy_baseline
  GW_LOSS=30 INET_LOSS=40 INET_LOSS_ALT=40
  diagnosis_run >/dev/null
  not_fired L1
  fired G2
}

@test "L1 yields to TCP-1 when ICMP is filtered but TCP works" {
  # Hotel/corporate networks drop ICMP wholesale. TCP-1 already explains
  # that; firing L1 as well would tell the user their ISP is down when
  # every real connection is fine.
  healthy_baseline
  GW_LOSS=100 INET_LOSS=100 INET_LOSS_ALT=100
  TCP_REACH_ANY_OK=1
  diagnosis_run >/dev/null
  fired TCP-1
  not_fired L1
}

@test "L1 and L2 stay silent when the loss probes never ran" {
  # --quick skips internet_ping_run entirely, leaving both vars empty.
  # Empty must read as "not measured", never as 0 or as 100.
  healthy_baseline
  INET_LOSS="" INET_LOSS_ALT=""
  diagnosis_run >/dev/null
  not_fired L1
  not_fired L2
}

@test "a single dropped packet out of 20 is not a warning" {
  # A transient single drop in twenty is an ordinary event on a real link.
  # The warn floor is two drops so that ordinary events stay quiet.
  healthy_baseline
  INET_LOSS=5 INET_LOSS_ALT=5
  diagnosis_run >/dev/null
  not_fired L2
  not_fired L1
  [ "$MAX_SEVERITY" -eq 0 ]
}

@test "every threshold lands on a whole number of dropped packets" {
  # 20 packets → a 5% quantum. If someone changes the packet count without
  # revisiting the floors, a threshold can land between two reportable
  # values and the band becomes unreachable — which is what the original
  # 8-packet probe did to every threshold below 12.5%.
  [ "$LOSS_PROBE_COUNT" -eq 20 ]
  [ "$LOSS_CRIT_PCT" -gt "$LOSS_WARN_PCT" ]
  [ $(( LOSS_WARN_PCT * LOSS_PROBE_COUNT % 100 )) -eq 0 ]
  [ $(( LOSS_CRIT_PCT * LOSS_PROBE_COUNT % 100 )) -eq 0 ]
}

@test "the loss probes pass no -t flag to ping" {
  # macOS ping's -t is a deadline for the WHOLE run, not a per-packet TTL.
  # `-c 20 -i 0.2 -t 2` transmitted 10 packets, not 20, and `-c 20 -i 0.1
  # -t 2` reported a permanent 5.0% loss because the final reply landed
  # after the deadline. Both artefacts read as network faults. The outer
  # bound belongs to with_timeout, which does not corrupt the measurement.
  run grep -nE '^[^#]*ping .*-t ' "$REPO/lib/internet_ping.sh" "$REPO/lib/gateway.sh"
  [ "$status" -ne 0 ]
}

@test "a real 20-packet probe transmits 20 packets and reports no loss" {
  # End-to-end guard on the flag set actually used, against loopback so it
  # needs no network and cannot be flaky. If -t ever comes back, or the
  # count and interval drift apart, the transmitted count stops matching.
  run ping -c "$LOSS_PROBE_COUNT" -i "$LOSS_PROBE_INTERVAL" 127.0.0.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"$LOSS_PROBE_COUNT packets transmitted"* ]]
  [[ "$output" == *"0.0% packet loss"* ]]
}

# ── ICMP-1: upstream ping filtering vs a real outage ─────────────────────

@test "ICMP-1: total loss to both targets with working TCP is filtering, not an outage" {
  # The dangerous false positive. Gateway answers, so L1's "router is
  # clean" guard is satisfied; both public targets show 100%; yet curl
  # fetched the public-IP page and TCP/443 connected. Real 100% loss
  # would have taken both of those with it, so this is an ISP or
  # middlebox dropping ICMP — common enough that calling it an outage
  # would fire a critical on a perfectly good connection.
  healthy_baseline
  INET_LOSS=100 INET_LOSS_ALT=100
  PUBLIC_OK=1 TCP_REACH_ANY_OK=1
  diagnosis_run >/dev/null
  fired ICMP-1
  not_fired L1
  not_fired L2
  [ "$MAX_SEVERITY" -eq 0 ]
}

@test "ICMP-1 does not mask a real outage when TCP is also failing" {
  healthy_baseline
  INET_LOSS=100 INET_LOSS_ALT=100
  PUBLIC_OK=0 TCP_REACH_ANY_OK=0
  diagnosis_run >/dev/null
  not_fired ICMP-1
  fired P2
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "ICMP-1 does not swallow partial loss that TCP retransmits through" {
  # 60% loss still lets curl and TCP succeed, but the connection is
  # genuinely broken for the user. Only *total* loss reads as filtering.
  healthy_baseline
  INET_LOSS=60 INET_LOSS_ALT=60
  PUBLIC_OK=1 TCP_REACH_ANY_OK=1
  diagnosis_run >/dev/null
  not_fired ICMP-1
  fired L1
  [ "$MAX_SEVERITY" -eq 2 ]
}

# ── L2 band ──────────────────────────────────────────────────────────────

@test "L2: moderate internet-side loss is a warning, not a critical" {
  healthy_baseline
  INET_LOSS=10 INET_LOSS_ALT=10
  diagnosis_run >/dev/null
  fired L2
  [ "$(sev_of L2)" = warn ]
  not_fired L1
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "L2 does not also fire once loss reaches L1's critical band" {
  healthy_baseline
  INET_LOSS=25 INET_LOSS_ALT=25
  diagnosis_run >/dev/null
  fired L1
  not_fired L2
}

@test "L2 reports decimal loss percentages without an arithmetic error" {
  # ping prints "12.5% packet loss"; a bare [ "$x" -ge 5 ] on that string
  # aborts the run under set -u/-e semantics.
  healthy_baseline
  INET_LOSS=12.5 INET_LOSS_ALT=12.5
  run diagnosis_run
  [ "$status" -eq 0 ]
  [[ "$output" != *"integer expression expected"* ]]
}

# ── G3: the gateway warn band ────────────────────────────────────────────

@test "G3: gateway loss under G1/G2's critical floor still warns" {
  healthy_baseline
  GW_LOSS=15
  diagnosis_run >/dev/null
  fired G3
  [ "$(sev_of G3)" = warn ]
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "G3 does not fire alongside G1/G2 in the critical band" {
  healthy_baseline
  GW_LOSS=25
  diagnosis_run >/dev/null
  fired G2
  not_fired G3
}

@test "G3 does not fire on a clean gateway" {
  healthy_baseline
  diagnosis_run >/dev/null
  not_fired G3
  [ "$MAX_SEVERITY" -eq 0 ]
}

# ── P1/P2 threshold amendment ────────────────────────────────────────────

@test "P2 still fires when the gateway has minor loss and the internet is down" {
  # The old guard was gateway.loss_pct == 0 exactly, so an outage measured
  # alongside 8% gateway loss fired neither P1/P2 (loss != 0) nor G1/G2
  # (loss < 20) — a total internet outage diagnosed as nothing at all.
  healthy_baseline
  GW_LOSS=8 PUBLIC_OK=0 DNS_OK=1
  diagnosis_run >/dev/null
  fired P2
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "P1 still fires with minor gateway loss when DNS is also down" {
  healthy_baseline
  GW_LOSS=8 PUBLIC_OK=0 DNS_OK=0
  diagnosis_run >/dev/null
  fired P1
}

@test "P1/P2 stay out of the way when the gateway is the actual problem" {
  healthy_baseline
  GW_LOSS=60 PUBLIC_OK=0 TCP_REACH_ANY_OK=0
  diagnosis_run >/dev/null
  not_fired P1
  not_fired P2
  fired G2
}

# ── add_diag return status ───────────────────────────────────────────────

@test "add_diag succeeds when a second diagnosis of the same severity is added" {
  # The case arms are `[ … ] && assign`, so the guard evaluating false
  # became the function's exit status. Two criticals in a row therefore
  # returned 1, which under set -e aborts the caller — diagnosis_run would
  # stop at the second critical and drop every rule after it.
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  add_diag critical X1 "first"
  run add_diag critical X2 "second"
  [ "$status" -eq 0 ]
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  add_diag warn Y1 "first"
  run add_diag warn Y2 "second"
  [ "$status" -eq 0 ]
  run add_diag info Z1 "info never bumps severity"
  [ "$status" -eq 0 ]
}

@test "diagnosis_run emits every critical when more than one fires" {
  healthy_baseline
  GW_LOSS=0 PUBLIC_OK=0 DNS_OK=1
  INET_LOSS=40 INET_LOSS_ALT=40
  diagnosis_run >/dev/null
  fired P2
  fired L1
  [ "$MAX_SEVERITY" -eq 2 ]
}

# ── speedtest flavour detection ──────────────────────────────────────────
# The Python speedtest-cli package installs a `speedtest` shim alongside
# `speedtest-cli`, so the binary's name says nothing about which tool it
# is. Branching on the name handed Ookla-only flags to the Python tool,
# which rejected them — and because the fallback was an elif on the same
# `command -v speedtest` test, it was unreachable. Every machine with only
# speedtest-cli installed silently reported "test ran but returned no
# result" on every default run.

# Put a fake speedtest binary on a PATH that contains nothing else but the
# system utilities, so whichever real speedtest happens to be installed on
# the machine running the suite can't be found instead and make the
# assertion pass or fail for the wrong reason. /usr/bin:/bin stays because
# bats' own teardown shells out to rm.
fake_speedtest() {
  local name="$1" banner="$2"
  FAKEBIN="$(mktemp -d)"
  cat >"$FAKEBIN/$name" <<EOF
#!/bin/sh
[ "\$1" = "--version" ] && { printf '%s\n' "$banner"; exit 0; }
exit 0
EOF
  chmod +x "$FAKEBIN/$name"
  PATH="$FAKEBIN:/usr/bin:/bin"
}

@test "a speedtest binary that is really speedtest-cli is detected as cli" {
  . "$REPO/lib/speedtest.sh"
  fake_speedtest speedtest "speedtest-cli 2.1.4b1"
  run speedtest_flavor
  [ "$output" = "cli:speedtest" ]
}

@test "Ookla's speedtest is detected as ookla" {
  . "$REPO/lib/speedtest.sh"
  fake_speedtest speedtest "Speedtest by Ookla 1.2.0.84 (ea6b6773cf) macOS/arm64"
  run speedtest_flavor
  [ "$output" = "ookla:speedtest" ]
}

@test "speedtest-cli alone is detected and named correctly" {
  . "$REPO/lib/speedtest.sh"
  fake_speedtest speedtest-cli "speedtest-cli 2.1.4b1"
  run speedtest_flavor
  [ "$output" = "cli:speedtest-cli" ]
}

@test "no speedtest installed reports none rather than guessing" {
  . "$REPO/lib/speedtest.sh"
  FAKEBIN="$(mktemp -d)"
  PATH="$FAKEBIN:/usr/bin:/bin"
  run speedtest_flavor
  [ "$output" = "none:" ]
}

# ── Unbounded probes ─────────────────────────────────────────────────────
# traceroute6 was 7.4 s of --quick's 10.6 s — 70% of the wall clock of the
# mode built to answer "is it up?" quickly — for a hop count that feeds no
# diagnosis rule and that default compact output never prints. It was also
# the only probe in lib/ipv6.sh with no wall-clock bound: -m 12 hops at
# -w 2 s is a 24 s worst case on a path that black-holes IPv6.

@test "traceroute6 is skipped under --quick" {
  run grep -n 'traceroute6 -n' "$REPO/lib/ipv6.sh"
  [ "$status" -eq 0 ]
  run grep -c 'QUICK.*-eq 0.*command -v traceroute6' "$REPO/lib/ipv6.sh"
  [ "$output" -eq 1 ]
}

@test "every network probe in lib/ipv6.sh has a wall-clock bound" {
  # ping6, dig and traceroute6 must all be wrapped; nc carries its own -G.
  local line
  while IFS= read -r line; do
    case "$line" in
      *with_timeout*) ;;
      *) printf 'unbounded probe: %s\n' "$line"; return 1 ;;
    esac
  # The trailing [-+] requires a flag, so this matches real invocations
  # (ping6 -c, traceroute6 -n, dig +time) and not prose that happens to
  # name the command inside a warn/info string.
  done < <(grep -hE '^[^#]*(ping6|traceroute6|dig) [-+]' "$REPO/lib/ipv6.sh")
}

@test "an unmeasured IPv6 hop count stays empty rather than reporting zero" {
  # --quick leaves IPV6_TRACE_HOPS unset; _maybe_int renders that as JSON
  # null. Defaulting it to 0 would claim a zero-hop path to Cloudflare.
  . "$REPO/lib/globals.sh"
  [ -z "$IPV6_TRACE_HOPS" ]
}

# ── Healthy networks stay healthy ────────────────────────────────────────

@test "a fully healthy network still reports nothing wrong and exits 0" {
  healthy_baseline
  run diagnosis_run
  [[ "$output" == *"Nothing obviously wrong"* ]]
  diagnosis_run >/dev/null
  [ "$MAX_SEVERITY" -eq 0 ]
}
