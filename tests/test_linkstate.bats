#!/usr/bin/env bats
#
# Unit tests for lib/linkstate.sh — the parsers that answer "is this Mac
# actually joined to something?" without asking for the default route.
#
# These exist because the whole N1 defect was a missing distinction: a
# machine with WiFi switched off and a machine sitting on a hotel network
# that has not handed out a route produced byte-identical netdiag state.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  # shellcheck source=../lib/linkstate.sh
  . "$REPO/lib/linkstate.sh"
}

@test "linkstate: ifconfig 'status: active' parses as active" {
  run linkstate_parse_ifconfig_status "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "active" ]
}

@test "linkstate: ifconfig 'status: inactive' parses as inactive" {
  run linkstate_parse_ifconfig_status "$(cat "$FIX/ifconfig_en0_inactive.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "inactive" ]
}

@test "linkstate: a device with no status line parses as empty, not active" {
  run linkstate_parse_ifconfig_status "lo0: flags=8049<UP,LOOPBACK> mtu 16384"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: the IPv4 address comes from the inet line, not inet6" {
  run linkstate_parse_ifconfig_ip "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "10.125.129.35" ]
}

@test "linkstate: no inet line yields an empty address" {
  run linkstate_parse_ifconfig_ip "$(cat "$FIX/ifconfig_en0_inactive.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: the DHCP router option parses out of getpacket" {
  run linkstate_parse_dhcp_router "$(cat "$FIX/ipconfig_getpacket.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "10.125.128.1" ]
}

@test "linkstate: only the first router is taken when several are offered" {
  run linkstate_parse_dhcp_router 'router (ip_mult): {10.0.0.1, 10.0.0.2}'
  [ "$status" -eq 0 ]
  [ "$output" = "10.0.0.1" ]
}

@test "linkstate: a lease with no router option yields empty" {
  run linkstate_parse_dhcp_router 'subnet_mask (ip): 255.255.255.0'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: service order yields devices in order, deduped" {
  run linkstate_parse_service_devices "$(cat "$FIX/networksetup_serviceorder.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "en5
bridge0
en0
en4" ]
}
