# shellcheck shell=bash
# lib/linkstate.sh — what the Mac is actually joined to, answered without
# asking for the default route.
#
# Why this file exists: lib/iface.sh derived both INTERFACE and GATEWAY
# from one `route -n get default`, and lib/wifi.sh, lib/dhcp.sh and
# lib/netid.sh all gate on INTERFACE. A missing default route therefore
# erased the SSID, the signal strength, the lease and the network identity
# along with the route — and N1 went on to tell the user their Mac "isn't
# joined to a WiFi network", a claim nothing in the run had checked. On a
# hotel network with a sign-in page, and on any network where the route
# flickers, that sentence is simply false.
#
# macOS will tell you the truth for free, three different ways, none of
# which involves the routing table:
#
#   ifconfig <dev>            → "status: active" once the link is up
#   ipconfig getifaddr <dev>  → the leased IPv4 address
#   ipconfig getpacket <dev>  → the DHCP ACK, including the router option
#
# "Joined but with no route" is a real and distinct network state, and it
# is the one a captive portal produces. Naming it is the whole point.
#
# Every parser takes its input as $1 rather than re-running the
# subprocess, so the callers keep control of caching and the tests can
# feed fixtures. Depends on nothing; safe to source standalone.
#
# Writes (via linkstate_run): LINK_DEVICE, LINK_STATUS, LINK_IP,
#                             LINK_DHCP_ROUTER, LINK_UP
# Entry: linkstate_run

# "active" / "inactive" / "" from `ifconfig <dev>` output ($1).
# Empty rather than "inactive" when there is no status line at all: a
# device that never reports one (lo0, utun*) is not the same as one that
# reports itself down, and the caller must be able to tell them apart.
linkstate_parse_ifconfig_status() {
  printf '%s\n' "$1" | awk '/^[[:space:]]*status:/{print $2; exit}'
}

# The IPv4 address from `ifconfig <dev>` output ($1), or empty.
# Anchored on "inet" as a whole word so the inet6 line can never match.
linkstate_parse_ifconfig_ip() {
  printf '%s\n' "$1" | awk '$1=="inet"{print $2; exit}'
}

# The first router the DHCP server offered, from `ipconfig getpacket <dev>`
# output ($1), or empty.
#
# The option is printed as `router (ip_mult): {10.0.0.1, 10.0.0.2}`. Only
# the first is taken: netdiag has exactly one notion of "the router", and
# a second one would have to be surfaced as a separate fact rather than
# silently substituted for the first.
linkstate_parse_dhcp_router() {
  printf '%s\n' "$1" | awk -F'[{}]' '
    /^[[:space:]]*router[[:space:]]*\(/ {
      split($2, a, ",")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[1])
      print a[1]
      exit
    }'
}

# Every device named in `networksetup -listnetworkserviceorder` output
# ($1), in service order, one per line. Order matters: it is macOS's own
# preference ranking, so the first active device in this list is the best
# available answer to "which interface is this Mac using" when there is no
# default route to ask.
linkstate_parse_service_devices() {
  printf '%s\n' "$1" | awk '
    match($0, /Device: [^)]+/) {
      d = substr($0, RSTART + 8, RLENGTH - 8)
      if (!(d in seen)) { seen[d] = 1; print d }
    }'
}

# Discover the link. $1 = optional device to check first (the default
# route's interface, when there is one) — checked before the service
# order so the fast path costs one ifconfig and nothing else.
#
# Sets LINK_DEVICE / LINK_STATUS / LINK_IP / LINK_DHCP_ROUTER / LINK_UP.
# LINK_UP is 1 only when a device is BOTH active AND holds an address:
# an active radio with no lease is associated but unconfigured, which is
# a fault worth naming, not a working link.
#
# Writes globals read by lib/iface.sh, lib/diagnosis.sh and emit_json.py.
# shellcheck disable=SC2034
linkstate_run() {
  local preferred="${1:-}" devices dev out
  LINK_DEVICE=""; LINK_STATUS=""; LINK_IP=""; LINK_DHCP_ROUTER=""; LINK_UP=0

  devices="$preferred"
  # The service order is only read when the preferred device did not
  # settle it, because networksetup costs ~100 ms and the overwhelming
  # majority of runs have a default route.
  if [ -z "$preferred" ]; then
    devices="$(linkstate_parse_service_devices \
      "$(networksetup -listnetworkserviceorder 2>/dev/null || true)")"
  fi

  for dev in $devices; do
    out="$(ifconfig "$dev" 2>/dev/null || true)"
    [ -n "$out" ] || continue
    local dev_status dev_ip
    dev_status="$(linkstate_parse_ifconfig_status "$out")"
    [ "$dev_status" = "active" ] || continue
    dev_ip="$(linkstate_parse_ifconfig_ip "$out")"
    LINK_DEVICE="$dev"
    LINK_STATUS="$dev_status"
    LINK_IP="$dev_ip"
    LINK_DHCP_ROUTER="$(linkstate_parse_dhcp_router \
      "$(ipconfig getpacket "$dev" 2>/dev/null || true)")"
    # An active device with an address ends the search. An active device
    # without one is remembered — it is still the best candidate we have,
    # and "associated but no address" is exactly the DHCP failure the
    # N1c rule needs to be able to describe — but the loop keeps looking
    # in case a later service is fully configured.
    if [ -n "$dev_ip" ]; then
      LINK_UP=1
      return 0
    fi
  done
  return 0
}
