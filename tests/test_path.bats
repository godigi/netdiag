#!/usr/bin/env bats
#
# lib/path.sh — what else is in the path besides the network.
#
# The bug this whole module addresses is one assumption wearing five
# different disguises: netdiag equates "carries my traffic" with "holds
# the default route". Split tunnels, PAC proxies and content filters each
# break that, and each silently invalidates a different subset of the
# report while every measurement still reads as a clean description of
# "the network".
#
# FIXTURE PROVENANCE. `netstat_rn_plain.txt` and
# `systemextensions_none.txt` are real captures from the machine this was
# written on — including the detail that it has six `utun` interfaces up
# and carrying no routes, which is the whole reason the split-tunnel
# check keys on routes rather than on interfaces. The split-tunnel,
# full-VPN and content-filter fixtures are constructed in those same
# observed formats: no VPN or network filter was installed here to
# capture.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  # shellcheck source=../lib/path.sh
  . "$REPO/lib/path.sh"
}

# ── Split-tunnel VPN [VPN-2] ─────────────────────────────────────────────

@test "path: an ordinary routing table has no tunnel routes" {
  # Real capture. This machine has utun0-utun5 all UP — existence alone
  # must mean nothing, or every Mac reports a split tunnel.
  run path_parse_tunnel_routes "$(cat "$FIX/netstat_rn_plain.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ] || { echo "found tunnels where there are none: '$output'"; return 1; }
}

@test "path: routes pointing at a utun are found" {
  run path_parse_tunnel_routes "$(cat "$FIX/netstat_rn_splittunnel.txt")"
  [ "$output" = "utun4" ] || { echo "got '$output'"; return 1; }
}

@test "path: a full-tunnel VPN is not reported as a split tunnel" {
  # The default route via utun4 is VPN-1's business. VPN-2 is for the
  # case VPN-1 cannot see, and double-reporting would be noise.
  run path_parse_tunnel_routes "$(cat "$FIX/netstat_rn_fullvpn.txt")"
  [ "$output" = "" ] || { echo "full VPN reported as split: '$output'"; return 1; }
}

@test "path: several tunnel interfaces are listed once each, in order" {
  local input='Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.1.1        UGScg                 en0
10.8.0/24          10.8.0.1           UGSc                utun4
10.20.0/16         10.8.0.1           UGSc                utun4
172.16.0/16        10.9.0.1           UGSc                utun7       '
  run path_parse_tunnel_routes "$input"
  [ "$output" = "utun4 utun7" ] || { echo "got '$output'"; return 1; }
}

@test "path: ipsec, ppp and wg tunnels count too" {
  local input='Destination        Gateway            Flags               Netif Expire
10.8.0/24          10.8.0.1           UGSc               ipsec0
10.9.0/24          10.9.0.1           UGSc                  wg0
10.10.0/24         10.10.0.1          UGSc                 ppp0       '
  run path_parse_tunnel_routes "$input"
  [ "$output" = "ipsec0 wg0 ppp0" ] || { echo "got '$output'"; return 1; }
}

@test "path: the header and banner lines are never parsed as routes" {
  run path_parse_tunnel_routes "$(printf 'Routing tables\n\nInternet:\n')"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
  run path_parse_tunnel_routes ""
  [ "$output" = "" ] || { echo "empty input gave '$output'"; return 1; }
}

# ── Web proxy / PAC [PX-1] ───────────────────────────────────────────────

@test "path: a disabled proxy is not enabled" {
  # Real capture from this machine.
  local out='Enabled: No
Server:
Port: 0
Authenticated Proxy Enabled: 0'
  run path_parse_proxy_enabled "$out"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
}

@test "path: an enabled manual proxy reports host and port" {
  local out='Enabled: Yes
Server: proxy.corp.example
Port: 8080
Authenticated Proxy Enabled: 0'
  run path_parse_proxy_enabled "$out"
  [ "$output" = "yes" ] || { echo "enabled gave '$output'"; return 1; }
  run path_parse_proxy_detail "$out"
  [ "$output" = "proxy.corp.example:8080" ] || { echo "detail gave '$output'"; return 1; }
}

@test "path: a PAC URL is reported instead of a host" {
  local out='URL: http://pac.corp.example/proxy.pac
Enabled: Yes'
  run path_parse_proxy_enabled "$out"
  [ "$output" = "yes" ]
  run path_parse_proxy_detail "$out"
  [ "$output" = "http://pac.corp.example/proxy.pac" ] || { echo "got '$output'"; return 1; }
}

@test "path: the literal string (null) is not reported as a PAC URL" {
  # Real capture: networksetup prints "URL: (null)" when none is set.
  local out='URL: (null)
Enabled: No'
  run path_parse_proxy_detail "$out"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
}

@test "path: a server with no port is reported without a bare colon" {
  run path_parse_proxy_detail "$(printf 'Enabled: Yes\nServer: proxy.example\nPort: 0\n')"
  [ "$output" = "proxy.example" ] || { echo "got '$output'"; return 1; }
}

# ── Content filters [FW-1] ───────────────────────────────────────────────

@test "path: camera and driver extensions are not network filters" {
  # Real capture. This machine has an OBS camera extension and a
  # Karabiner driver extension; neither is in the datapath, and
  # reporting them would be a false alarm on a very common setup.
  run path_parse_network_extensions "$(cat "$FIX/systemextensions_none.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ] || { echo "non-network extensions reported: '$output'"; return 1; }
}

@test "path: network extensions are listed by bundle id" {
  run path_parse_network_extensions "$(cat "$FIX/systemextensions_filter.txt")"
  [ "$output" = "com.netskope.client.Netskope-Client.NetskopeClientExtension com.getlittlesnitch.daemon" ] \
    || { echo "got '$output'"; return 1; }
}

@test "path: a filter with no leading enabled column is still found" {
  # The `enabled` column is blank for an extension awaiting approval —
  # the second entry in the fixture above. Indexing from the left would
  # miss it; the parser anchors on the parenthesised version instead.
  run path_parse_network_extensions "$(cat "$FIX/systemextensions_filter.txt")"
  case "$output" in
    *com.getlittlesnitch.daemon*) ;;
    *) echo "the unapproved extension was missed: '$output'"; return 1 ;;
  esac
}

@test "path: the column header is never read as an extension" {
  run path_parse_network_extensions "$(printf -- '--- com.apple.system_extension.network_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n')"
  [ "$output" = "" ] || { echo "header parsed as an extension: '$output'"; return 1; }
}

@test "path: no extensions at all yields nothing, not an error" {
  run path_parse_network_extensions ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run path_parse_network_extensions "0 extension(s)"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
