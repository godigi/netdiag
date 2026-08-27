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

# ── Ethernet negotiation [ETH-1, ETH-2] ──────────────────────────────────
#
# A damaged pair in a cable, or a cheap dock, drops a 1000BASE-T link to
# 100BASE-TX. A 10x cap, invisible everywhere except this one line, and
# the speed test then reads as a slow ISP.
#
# NOTE ON THE FIXTURES: the gigabit/100/half-duplex files are constructed
# from macOS's documented `ifconfig -m` format, not captured — the machine
# this was written on has no wired Ethernet to plug a bad cable into. The
# `autoselect <full-duplex>` and `media: none` shapes below ARE real
# captures from that machine's virtual and unplugged interfaces.

@test "linkstate: a gigabit link reports 1000 Mb/s, full duplex" {
  run linkstate_parse_media_rate "$(cat "$FIX/ifconfig_m_en5_gigabit.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ] || { echo "got '$output'"; return 1; }
  run linkstate_parse_media_duplex "$(cat "$FIX/ifconfig_m_en5_gigabit.txt")"
  [ "$output" = "full" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: a 100BASE-TX link reports 100 Mb/s" {
  run linkstate_parse_media_rate "$(cat "$FIX/ifconfig_m_en5_100mbit.txt")"
  [ "$output" = "100" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: 10baseT/UTP half duplex parses as 10 and half" {
  run linkstate_parse_media_rate "$(cat "$FIX/ifconfig_m_en5_halfduplex.txt")"
  [ "$output" = "10" ] || { echo "got '$output'"; return 1; }
  run linkstate_parse_media_duplex "$(cat "$FIX/ifconfig_m_en5_halfduplex.txt")"
  [ "$output" = "half" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: the supported list yields the port's top speed" {
  run linkstate_parse_media_max "$(cat "$FIX/ifconfig_m_en5_100mbit.txt")"
  [ "$output" = "1000" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: WiFi's bare 'autoselect' has no negotiated rate" {
  # Real capture. Wi-Fi reports no media subtype, and inventing one would
  # make every wireless run fire an Ethernet rule.
  run linkstate_parse_media_rate "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
  run linkstate_parse_media_max "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: a virtual interface's 'autoselect <full-duplex>' has no rate" {
  # Real capture from a Thunderbolt bridge member: duplex stated, no
  # speed. Parsing the duplex out of this must not imply a rate.
  local out='	media: autoselect <full-duplex>
	status: inactive'
  run linkstate_parse_media_rate "$out"
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
  run linkstate_parse_media_duplex "$out"
  [ "$output" = "full" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: 'media: none' and '<unknown type>' yield nothing" {
  # Both are real captures from unplugged/virtual devices here.
  run linkstate_parse_media_rate '	media: none'
  [ "$output" = "" ] || { echo "none gave '$output'"; return 1; }
  run linkstate_parse_media_rate '	media: <unknown type>'
  [ "$output" = "" ] || { echo "unknown gave '$output'"; return 1; }
  run linkstate_parse_media_duplex '	media: none'
  [ "$output" = "" ] || { echo "none duplex gave '$output'"; return 1; }
}

@test "linkstate: flow-control in the media options does not break the parse" {
  # 1000baseT links commonly report <full-duplex,flow-control>.
  run linkstate_parse_media_rate '	media: autoselect (1000baseT <full-duplex,flow-control>)'
  [ "$output" = "1000" ] || { echo "got '$output'"; return 1; }
  run linkstate_parse_media_duplex '	media: autoselect (1000baseT <full-duplex,flow-control>)'
  [ "$output" = "full" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: a 2.5G/10G port parses rather than being read as 2 or 10" {
  run linkstate_parse_media_rate '	media: autoselect (2500Base-T <full-duplex>)'
  [ "$output" = "2500" ] || { echo "2.5G gave '$output'"; return 1; }
  run linkstate_parse_media_rate '	media: autoselect (10Gbase-T <full-duplex>)'
  [ "$output" = "10000" ] || { echo "10G gave '$output'"; return 1; }
}

@test "linkstate: a media line without parentheses still yields its rate" {
  # A manually pinned link reports `media: 100baseTX <full-duplex>` with
  # no autoselect wrapper.
  run linkstate_parse_media_rate '	media: 100baseTX <full-duplex>'
  [ "$output" = "100" ] || { echo "got '$output'"; return 1; }
}

# ── Metered links [MET-1] ────────────────────────────────────────────────
# The speed test runs by default and moves hundreds of megabytes. On a
# phone's hotspot that is the user's money.

@test "linkstate: a device resolves to its service name" {
  # The name and the device sit on separate lines, so the parser has to
  # carry the name forward from the previous one.
  run linkstate_service_for_device \
    "$(cat "$FIX/networksetup_serviceorder.txt")" en0
  [ "$status" -eq 0 ]
  [ "$output" = "Wi-Fi" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: an unknown device resolves to no service" {
  run linkstate_service_for_device \
    "$(cat "$FIX/networksetup_serviceorder.txt")" en99
  [ "$output" = "" ] || { echo "got '$output'"; return 1; }
}

@test "linkstate: tethered service names are recognised" {
  # These are macOS's own names, not guesses — this developer's service
  # order lists "iPhone USB".
  for s in "iPhone USB" "iPad USB" "Bluetooth PAN" "Personal Hotspot" \
           "Brian's iPhone Hotspot"; do
    run linkstate_is_tethered_service "$s"
    [ "$status" -eq 0 ] || { echo "'$s' not recognised as tethered"; return 1; }
  done
}

@test "linkstate: ordinary service names are not tethered" {
  for s in "Wi-Fi" "Ethernet" "Thunderbolt Bridge" "USB 10/100 LAN" ""; do
    run linkstate_is_tethered_service "$s"
    [ "$status" -ne 0 ] || { echo "'$s' wrongly called tethered"; return 1; }
  done
}

@test "linkstate: the documented hotspot subnets are recognised" {
  run linkstate_is_hotspot_subnet "172.20.10.3"   # iOS default
  [ "$status" -eq 0 ] || { echo "iOS range missed"; return 1; }
  run linkstate_is_hotspot_subnet "192.168.43.17"  # Android default
  [ "$status" -eq 0 ] || { echo "Android range missed"; return 1; }
}

@test "linkstate: ordinary home subnets are not hotspots" {
  for ip in "192.168.1.4" "10.0.0.5" "172.20.11.3" "192.168.4.3" ""; do
    run linkstate_is_hotspot_subnet "$ip"
    [ "$status" -ne 0 ] || { echo "'$ip' wrongly called a hotspot"; return 1; }
  done
}

@test "linkstate: 172.20.100.x is not mistaken for the iOS range" {
  # A prefix compare done on the string rather than the octet would match
  # 172.20.10 inside 172.20.100.
  run linkstate_is_hotspot_subnet "172.20.100.5"
  [ "$status" -ne 0 ] || { echo "172.20.100.5 wrongly matched"; return 1; }
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
  # linkstate_run calls `ifconfig -m <dev>`, so the device is the LAST
  # argument, not the first. A mock switching on $1 would see "-m" and
  # answer for no device at all.
  ifconfig() {
    case "${@: -1}" in
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

@test "iface: a link on the iPhone USB service is marked metered" {
  iface_setup
  # A default route exists and points at en4, so the fast path runs and
  # the service order is never read by the device walk — the metered
  # lookup has to fetch it itself.
  route() { printf 'gateway: 172.20.10.1\ninterface: en4\n'; }
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
  [ "$LINK_SERVICE" = "iPhone USB" ] || { echo "LINK_SERVICE='$LINK_SERVICE'"; return 1; }
  [ "$LINK_METERED" -eq 1 ] || { echo "LINK_METERED=$LINK_METERED"; return 1; }
}

@test "iface: an ordinary Wi-Fi link is not metered" {
  iface_setup
  route() { printf 'gateway: 10.125.128.1\ninterface: en0\n'; }
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
  [ "$LINK_SERVICE" = "Wi-Fi" ] || { echo "LINK_SERVICE='$LINK_SERVICE'"; return 1; }
  [ "$LINK_METERED" -eq 0 ] || { echo "LINK_METERED=$LINK_METERED on plain WiFi"; return 1; }
}

@test "iface: a Wi-Fi link on the iOS hotspot subnet is metered" {
  # A phone's Wi-Fi hotspot is an ordinary Wi-Fi service as far as macOS
  # is concerned, so the service name says nothing and the address is
  # the only signal there is.
  iface_setup
  route() { printf 'gateway: 172.20.10.1\ninterface: en0\n'; }
  netstat() { return 1; }
  ifconfig() { printf '\tinet 172.20.10.4 netmask 0xfffffff0\n\tmedia: autoselect\n\tstatus: active\n'; }
  ipconfig() {
    case "$1" in
      getpacket) printf 'router (ip_mult): {172.20.10.1}\n' ;;
      getifaddr) printf '172.20.10.4\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$LINK_SERVICE" = "Wi-Fi" ] || { echo "LINK_SERVICE='$LINK_SERVICE'"; return 1; }
  [ "$LINK_METERED" -eq 1 ] || { echo "LINK_METERED=$LINK_METERED on the iOS hotspot range"; return 1; }
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

# ── The run measured one network, not two [DQ-1] ─────────────────────────
#
# A full check takes ~60 s. Walk out of Wi-Fi range onto Ethernet at
# second 30 and the run blends two networks, then stamps the result with
# one network.id and files it in one network's history — where BL-1 later
# judges future runs against it. Roaming between two mesh APs does the
# same to W1/W2: one averaged RSSI describing neither radio.

netid_setup() {
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
}

@test "netid: a fingerprint is built from the four cheap identity signals" {
  netid_setup
  run netid_fingerprint "en0" "192.168.1.1" "Home" "aa:bb:cc:dd:ee:ff"
  [ "$status" -eq 0 ]
  [ "$output" = "en0|192.168.1.1|Home|aa:bb:cc:dd:ee:ff" ] || { echo "got '$output'"; return 1; }
}

@test "netid: missing parts still produce a comparable fingerprint" {
  # An unprivileged run has no BSSID and a hidden SSID. The fingerprint
  # must still be stable across two calls in the same conditions, or
  # DQ-1 fires on every such run.
  netid_setup
  local a b
  a="$(netid_fingerprint "en0" "192.168.1.1" "" "")"
  b="$(netid_fingerprint "en0" "192.168.1.1" "" "")"
  [ "$a" = "$b" ] || { echo "'$a' != '$b'"; return 1; }
  [ -n "$a" ] || { echo "empty fingerprint"; return 1; }
}

@test "netid: a changed network is detected" {
  netid_setup
  local before after
  before="$(netid_fingerprint "en0" "192.168.1.1" "Home" "")"
  after="$(netid_fingerprint "en5" "10.0.0.1" "" "")"
  netid_fingerprint_changed "$before" "$after" \
    || { echo "WiFi -> ethernet not detected"; return 1; }
}

@test "netid: a roam to another BSSID on the same SSID is detected" {
  # Same network name, different radio. W1/W2 would otherwise average
  # two APs' signal into one number describing neither.
  netid_setup
  netid_fingerprint_changed \
    "$(netid_fingerprint en0 192.168.1.1 Home aa:bb:cc:dd:ee:01)" \
    "$(netid_fingerprint en0 192.168.1.1 Home aa:bb:cc:dd:ee:02)" \
    || { echo "roam not detected"; return 1; }
}

@test "netid: an unchanged network is not flagged" {
  netid_setup
  local fp; fp="$(netid_fingerprint en0 192.168.1.1 Home aa:bb:cc:dd:ee:ff)"
  netid_fingerprint_changed "$fp" "$fp" \
    && { echo "a stable network was flagged as changed"; return 1; }
  return 0
}

@test "netid: an unknown fingerprint on either side is never a change" {
  # The failure this prevents: a check that could not read the identity
  # at one end reports "your network changed" on every single run. An
  # absent reading is not evidence of a change.
  netid_setup
  local fp; fp="$(netid_fingerprint en0 192.168.1.1 Home "")"
  netid_fingerprint_changed "" "$fp" && { echo "empty before flagged"; return 1; }
  netid_fingerprint_changed "$fp" "" && { echo "empty after flagged"; return 1; }
  netid_fingerprint_changed "" ""    && { echo "both empty flagged"; return 1; }
  return 0
}

@test "netid: a fingerprint with only empty fields counts as unknown" {
  # "|||" carries no identity at all and must not compare equal to a
  # real one, nor count as a reading.
  netid_setup
  local blank; blank="$(netid_fingerprint "" "" "" "")"
  netid_fingerprint_changed "$blank" "$(netid_fingerprint en0 192.168.1.1 Home "")" \
    && { echo "a contentless fingerprint was treated as a reading"; return 1; }
  return 0
}
