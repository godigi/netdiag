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

# ── A self-assigned address is not an address [DH-3] ─────────────────────
#
# macOS falls back to 169.254.0.0/16 when no DHCP server answers. That is
# not connectivity, it is the OS announcing the absence of it — but it
# arrives on the same `inet` line as a real lease, so every parser that
# takes the first `inet` it sees reports a configured link.

@test "linkstate: a 169.254 address is recognised as self-assigned" {
  run linkstate_is_link_local "169.254.211.7"
  [ "$status" -eq 0 ]
}

@test "linkstate: a real RFC1918 address is not self-assigned" {
  run linkstate_is_link_local "10.125.129.35"
  [ "$status" -ne 0 ]
  run linkstate_is_link_local "192.168.1.4"
  [ "$status" -ne 0 ]
}

@test "linkstate: 169.254 is matched on the octet, not the digits" {
  # 169.2540 and 16.9.254.x must not match a prefix compare done wrong,
  # and a host in 169.255/16 or 168.254/16 is ordinary public space.
  run linkstate_is_link_local "169.255.1.1"
  [ "$status" -ne 0 ]
  run linkstate_is_link_local "168.254.1.1"
  [ "$status" -ne 0 ]
  run linkstate_is_link_local "16.9.254.1"
  [ "$status" -ne 0 ]
}

@test "linkstate: an empty address is not self-assigned" {
  # No address at all is a different state from a made-up one, and the
  # caller distinguishes them. Returning true here would collapse both
  # into DH-3 and lose N1's "nothing joined".
  run linkstate_is_link_local ""
  [ "$status" -ne 0 ]
}

@test "linkstate: a self-assigned address still parses out of ifconfig" {
  # The parser reports what is there; the judgement is the caller's.
  run linkstate_parse_ifconfig_ip "$(cat "$FIX/ifconfig_en0_linklocal.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "169.254.211.7" ]
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

# ── iface_run: the route is one input, not the only one ──────────────────

iface_setup() {
  JSON_MODE=0 QUIET=0 QUICK=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/iface.sh
  . "$REPO/lib/iface.sh"
}

@test "iface: a joined link with no default route keeps INTERFACE and reports LINK_UP" {
  iface_setup
  # No default route, but en0 is active and holds a lease.
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_active.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$GATEWAY" = "" ]
  [ "$LINK_UP" -eq 1 ]
  [ "$INTERFACE" = "en5" ]
  [ "$LOCAL_IP" = "10.125.129.35" ]
  [ "$LINK_DHCP_ROUTER" = "10.125.128.1" ]
}

@test "iface: nothing joined leaves LINK_UP at zero" {
  iface_setup
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_inactive.txt"; }
  ipconfig() { return 1; }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$LINK_UP" -eq 0 ]
  [ "$INTERFACE" = "" ]
  [ "$LINK_DHCP_ROUTER" = "" ]
}

@test "iface: a self-assigned address does not count as a configured link" {
  # The defect: linkstate_parse_ifconfig_ip took the first `inet` line
  # whatever it was, so a total DHCP failure set LINK_IP and LINK_UP=1 and
  # the report described a healthy, configured link. The one thing this
  # file exists to distinguish, folded into the healthy case.
  iface_setup
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_linklocal.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) return 1 ;;
      getifaddr) printf '169.254.211.7\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$LINK_UP" -eq 0 ] || { echo "LINK_UP=$LINK_UP with only a self-assigned address"; return 1; }
  # The device and the address are still reported — DH-3 has to be able to
  # name which interface failed to get a lease, and quote what it made up.
  [ "$LINK_DEVICE" = "en5" ] || { echo "LINK_DEVICE=$LINK_DEVICE"; return 1; }
  [ "$LINK_SELF_ASSIGNED" -eq 1 ] || { echo "LINK_SELF_ASSIGNED=$LINK_SELF_ASSIGNED"; return 1; }
}

@test "iface: a real lease leaves LINK_SELF_ASSIGNED at zero" {
  iface_setup
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_active.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$LINK_UP" -eq 1 ]
  [ "$LINK_SELF_ASSIGNED" -eq 0 ] || { echo "LINK_SELF_ASSIGNED=$LINK_SELF_ASSIGNED on a real lease"; return 1; }
}

@test "iface: a configured device outranks an earlier self-assigned one" {
  # The service order walk must not stop at the first active device when
  # that device only has a made-up address and a later one has a lease.
  iface_setup
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() {
    case "$1" in
      en5) cat "$FIX/ifconfig_en0_linklocal.txt" ;;
      en0) cat "$FIX/ifconfig_en0_active.txt" ;;
      *)   return 1 ;;
    esac
  }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$LINK_UP" -eq 1 ] || { echo "LINK_UP=$LINK_UP"; return 1; }
  [ "$LINK_DEVICE" = "en0" ] || { echo "LINK_DEVICE=$LINK_DEVICE, expected the leased en0"; return 1; }
  [ "$LINK_SELF_ASSIGNED" -eq 0 ] || { echo "LINK_SELF_ASSIGNED=$LINK_SELF_ASSIGNED"; return 1; }
}

@test "iface: the route is re-read once before it is called missing" {
  iface_setup
  # First read returns nothing, second returns a real route — the flicker
  # this re-check exists for.
  ROUTE_CALLS_FILE="$BATS_TEST_TMPDIR/route_calls"
  printf '0' > "$ROUTE_CALLS_FILE"
  route() {
    local n
    n="$(cat "$ROUTE_CALLS_FILE")"
    printf '%s' "$((n + 1))" > "$ROUTE_CALLS_FILE"
    [ "$n" -eq 0 ] && return 0
    printf 'gateway: 10.125.128.1\ninterface: en0\n'
  }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_active.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$GATEWAY" = "10.125.128.1" ]
  [ "$INTERFACE" = "en0" ]
  [ "$(cat "$ROUTE_CALLS_FILE")" -ge 2 ]
}
