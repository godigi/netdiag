#!/usr/bin/env bats
#
# Regression guards for three false-signal bugs found by running netdiag
# against a live dual-stack home network. All three shared a shape: a
# measurement silently failed, and the failure was rendered as a confident
# statement about the user's network rather than as missing data.
#
#   1. progress_spin_start orphaned the spinner already running, so two
#      background processes overwrote the same stderr line at 10 Hz and the
#      label flickered between "Public reachability" and the live section.
#   2. The DHCP-vs-system DNS check compared only nameserver[0] using a
#      substring test, so the router's RA-learned IPv6 resolver read as a
#      manual override on every dual-stack network.
#   3. macOS ping6's -W is a boolean, not a timeout. "-W 2000" made 2000
#      the hostname, ping6 exited before sending a packet, and the empty
#      output was defaulted to 100% loss — a permanent false "IPv6 broken".

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 LOG=/dev/null
  SPUN=()
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
}

# Reap anything a failing spinner assertion left behind. Without this a
# regression doesn't just fail the test, it hangs the whole suite: the
# orphan inherits bats' stdout pipe and holds it open forever.
teardown() {
  local p
  for p in "${SPUN[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  return 0
}

# ── 1. Spinner lifecycle ─────────────────────────────────────────────────
# bats' stderr is a pipe, so _progress_active would short-circuit and every
# spinner assertion below would pass vacuously. Force the gate open.
force_progress() { _progress_active() { return 0; }; }

# Start a spinner with both fds detached, so a leaked child can never pin
# bats' capture pipe open, and record its pid for teardown.
spin() {
  progress_spin_start "$1" >/dev/null 2>&1
  SPUN+=("$_progress_spinner_pid")
}

@test "progress_spin_start stops a spinner that is already running" {
  force_progress
  spin first
  local first="$_progress_spinner_pid"
  [ -n "$first" ]
  kill -0 "$first"

  spin second
  local second="$_progress_spinner_pid"
  [ "$second" != "$first" ]

  # The bug: "first" was never killed, so it kept printing "first…" while
  # "second" printed "second…" — 10 Hz flicker between two labels.
  run kill -0 "$first"
  [ "$status" -ne 0 ]

  progress_spin_stop >/dev/null 2>&1
  run kill -0 "$second"
  [ "$status" -ne 0 ]
}

@test "no spinner outlives the run that started it" {
  force_progress
  spin alpha
  local alpha="$_progress_spinner_pid"
  spin beta
  local beta="$_progress_spinner_pid"
  progress_spin_stop >/dev/null 2>&1

  # An orphan here would keep writing to the user's terminal after netdiag
  # had already exited and returned the prompt.
  run kill -0 "$alpha"; [ "$status" -ne 0 ]
  run kill -0 "$beta";  [ "$status" -ne 0 ]
}

@test "bin/netdiag clears the spinner from its EXIT trap" {
  run grep -n "progress_spin_stop" "$REPO/bin/netdiag"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_netdiag_on_exit"* || "$output" == *"spin_stop"* ]]
  # The trap body itself must reference it, so Ctrl-C can't strand a spinner.
  run awk '/^_netdiag_on_exit\(\)/,/^}/' "$REPO/bin/netdiag"
  [[ "$output" == *"progress_spin_stop"* ]]
}

# ── 2. DHCP-vs-system DNS override detection ─────────────────────────────

@test "dual-stack: RA-learned IPv6 resolver plus the DHCP v4 server is not an override" {
  # The exact configuration that produced the false report: macOS lists the
  # router's link-local first and the DHCP-handed v4 server second.
  run dns_is_manual_override "192.168.15.1" "fe80::1298:5fff:fe91:2f00%en0 192.168.15.1"
  [ "$status" -ne 0 ]
}

@test "a link-local-only resolver list is never called an override" {
  # A scoped link-local address can't be typed into System Settings — it is
  # always the router's own RA/RDNSS advertisement.
  run dns_is_manual_override "192.168.15.1" "fe80::1298:5fff:fe91:2f00%en0"
  [ "$status" -ne 0 ]
}

@test "a genuinely overridden resolver is still reported" {
  run dns_is_manual_override "192.168.15.1" "1.1.1.1 8.8.8.8"
  [ "$status" -eq 0 ]
}

@test "override detection compares whole addresses, not substrings" {
  # 192.168.15.1 is a substring of 192.168.15.10, so the old grep -F test
  # silently swallowed a real override.
  run dns_is_manual_override "192.168.15.10" "192.168.15.1"
  [ "$status" -eq 0 ]
}

@test "missing DHCP DNS data makes no override claim" {
  run dns_is_manual_override "" "1.1.1.1"
  [ "$status" -ne 0 ]
}

@test "missing system resolver data makes no override claim" {
  run dns_is_manual_override "192.168.15.1" ""
  [ "$status" -ne 0 ]
}

@test "comma-separated DHCP lists are split into individual addresses" {
  run dns_is_manual_override "192.168.15.1, 192.168.15.2" "192.168.15.2"
  [ "$status" -ne 0 ]
}

@test "dns_routable_resolvers drops link-local entries from the reported list" {
  run dns_routable_resolvers "fe80::1298:5fff:fe91:2f00%en0 192.168.15.1"
  [ "$output" = "192.168.15.1" ]
}

@test "DH-2 does not fire on a dual-stack network using the router's DNS" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.15.1
  DHCP_DNS_SERVERS="192.168.15.1"
  SYS_RES_ALL="fe80::1298:5fff:fe91:2f00%en0 192.168.15.1"
  SYS_RES="fe80::1298:5fff:fe91:2f00%en0"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " != *" DH-2 "* ]]
}

@test "DH-2 still fires when the resolver really was replaced" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.15.1
  DHCP_DNS_SERVERS="192.168.15.1"
  SYS_RES_ALL="1.1.1.1 8.8.8.8"
  SYS_RES="1.1.1.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " == *" DH-2 "* ]]
}

# ── 3. ping6 flags and unknown-vs-broken IPv6 ────────────────────────────

@test "ping6 accepts the flags ipv6_run uses and reports statistics" {
  # Loopback, so this needs no network. macOS ping6's -W is a boolean in
  # the [-DdfHmnNoqrRtvwW] cluster; the old "-W 2000" made 2000 the
  # hostname and ping6 died with "nodename nor servname provided".
  run ping6 -c 2 -i 0.2 ::1
  [ "$status" -eq 0 ]
  [[ "$output" == *"packet loss"* ]]
}

@test "lib/ipv6.sh does not pass -W to ping6" {
  run grep -n "ping6 " "$REPO/lib/ipv6.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"-W"* ]]
}

@test "ipv6_parse_ping_loss reads the loss percentage" {
  # shellcheck source=../lib/ipv6.sh
  . "$REPO/lib/ipv6.sh"
  run ipv6_parse_ping_loss "5 packets transmitted, 4 packets received, 20.0% packet loss"
  [ "$output" = "20.0" ]
}

@test "ipv6_parse_ping_loss returns empty for output it cannot parse" {
  # Defaulting to 100 turned "the measurement failed" into "your network is
  # broken" — the whole substance of the ping6 bug.
  . "$REPO/lib/ipv6.sh"
  run ipv6_parse_ping_loss ""
  [ -z "$output" ]
  run ipv6_parse_ping_loss "ping6: nodename nor servname provided, or not known"
  [ -z "$output" ]
}

@test "V6-1 does not fire when only the ping6 measurement is missing" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.15.1
  PUBLIC_OK=1
  IPV6_AVAILABLE=1 IPV6_PING_LOSS="" IPV6_AAAA_OK=1 IPV6_TCP_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " != *" V6-1 "* ]]
}

@test "V6-1 still fires on genuinely lossy IPv6" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.15.1
  PUBLIC_OK=1
  IPV6_AVAILABLE=1 IPV6_PING_LOSS="100" IPV6_AAAA_OK=1 IPV6_TCP_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]:-} " == *" V6-1 "* ]]
}
