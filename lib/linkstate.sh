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
#                             LINK_DHCP_ROUTER, LINK_UP, LINK_SELF_ASSIGNED,
#                             LINK_MEDIA_MBPS, LINK_MEDIA_MAX_MBPS,
#                             LINK_DUPLEX, LINK_MEDIA_FULL_DUPLEX_CAPABLE
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
#
# Reports what is on the wire, including a self-assigned 169.254 address.
# Judging it is linkstate_is_link_local's job and the caller's decision:
# a parser that silently dropped the address would leave DH-3 unable to
# say which interface failed and what it made up instead.
linkstate_parse_ifconfig_ip() {
  printf '%s\n' "$1" | awk '$1=="inet"{print $2; exit}'
}

# True when $1 is an IPv4 link-local (self-assigned) address, 169.254/16.
#
# macOS assigns one of these when it asks a network for an address and
# nothing answers. It is the OS reporting the *absence* of a lease, but it
# arrives on the same `inet` line as a real one — so treating "has an
# inet address" as "is configured" turns a total DHCP failure into a
# healthy link. That is precisely what happened: linkstate_run set
# LINK_UP=1 and returned on the first active device, and the report went
# on to describe a configured network that could not reach anything, with
# no cause named.
#
# Empty is deliberately *not* link-local. No address at all is a distinct
# state — N1's "nothing joined" — and collapsing the two would lose it.
#
# Matched on the dotted octets rather than a string prefix, so 169.255.x,
# 168.254.x and 16.9.254.x stay the ordinary public addresses they are.
linkstate_is_link_local() {
  case "${1:-}" in
    169.254.*.*) return 0 ;;
    *)           return 1 ;;
  esac
}

# ── Ethernet negotiation [ETH-1, ETH-2] ──────────────────────────────────
#
# A damaged pair in a cable, a cheap dock, or a switch port stuck on a
# forced setting drops a 1000BASE-T link to 100BASE-TX — a 10x cap that
# is invisible everywhere in netdiag except this one line of ifconfig.
# The speed test then reports ~94 Mb/s and the user calls their ISP about
# a gigabit plan that is being delivered correctly.
#
# Half duplex is the same family and worse: collisions and heavy loss,
# which G2/G3 would otherwise report as "your router is dropping packets"
# and send the user to reboot a box that is fine.
#
# Both come off `ifconfig -m <dev>`, which is a superset of plain
# `ifconfig <dev>` — same status and inet lines, plus the `supported
# media:` block — so linkstate_run gets the capability for free without a
# second subprocess. `networksetup -listvalidmedia` would also answer,
# but it takes a hardware-port name rather than a device and costs ~100ms.

# Rate in Mb/s from a `media:` line in `ifconfig` output ($1), or empty.
#
# Shapes this must handle, all real:
#   media: autoselect (1000baseT <full-duplex>)      negotiated gigabit
#   media: autoselect (1000baseT <full-duplex,flow-control>)
#   media: 100baseTX <full-duplex>                   manually pinned
#   media: autoselect (2500Base-T <full-duplex>)     2.5 GbE, mixed case
#   media: autoselect                                WiFi — no rate
#   media: autoselect <full-duplex>                  virtual — no rate
#   media: none / <unknown type>                     unplugged — no rate
#
# Empty for everything without a speed in it. Wi-Fi reports a bare
# `autoselect`, and inventing a rate for it would fire an Ethernet rule
# on every wireless run.
#
# The unit suffix is what distinguishes 10Gbase-T (10000) from
# 10baseT/UTP (10), so it is matched explicitly rather than taking the
# leading digits.
linkstate_parse_media_rate() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*media:/ {
      line = tolower($0)
      if (match(line, /[0-9]+g?base/)) {
        spec = substr(line, RSTART, RLENGTH)
        n = spec + 0
        # "10gbase-t" → 10 × 1000; "1000baset" → 1000 as it stands.
        print (spec ~ /gbase/) ? n * 1000 : n
      }
      exit
    }'
}

# "full" | "half" | "" from a `media:` line in `ifconfig` output ($1).
# Independent of the rate: a virtual interface states its duplex and no
# speed, and a rate parser that also owned duplex would lose that.
linkstate_parse_media_duplex() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*media:/ {
      line = tolower($0)
      if (line ~ /half-duplex/) { print "half"; exit }
      if (line ~ /full-duplex/) { print "full"; exit }
      exit
    }'
}

# The highest rate in Mb/s the port advertises, from the `supported
# media:` block of `ifconfig -m <dev>` output ($1), or empty.
#
# This is the port's capability, which is what makes ETH-1 possible:
# "100 Mb/s" is only a fault relative to a port that can do more, and on
# a genuinely 100 Mb/s-only adapter it is simply the truth.
linkstate_parse_media_max() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*supported media:/ { in_block = 1; next }
    in_block && /^[[:space:]]*media / {
      line = tolower($0)
      if (match(line, /[0-9]+g?base/)) {
        spec = substr(line, RSTART, RLENGTH)
        n = spec + 0
        if (spec ~ /gbase/) n *= 1000
        if (n > max) max = n
      }
      next
    }
    in_block && !/^[[:space:]]*media / { in_block = 0 }
    END { if (max > 0) print max }'
}

# True when the `supported media:` block of `ifconfig -m <dev>` output
# ($1) advertises any full-duplex mode.
#
# This is what makes ETH-2 a fault rather than an observation. A link
# running half duplex on a port that can do full duplex is a failed
# negotiation — usually one end pinned to a fixed setting — and it
# produces collisions and heavy loss. A port that only ever does half
# duplex is simply old, and saying so would be noise.
linkstate_media_has_full_duplex() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*supported media:/ { in_block = 1; next }
    in_block && /^[[:space:]]*media / {
      if (tolower($0) ~ /full-duplex/) { found = 1 }
      next
    }
    in_block && !/^[[:space:]]*media / { in_block = 0 }
    END { exit(found ? 0 : 1) }'
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
# Sets LINK_DEVICE / LINK_STATUS / LINK_IP / LINK_DHCP_ROUTER / LINK_UP /
# LINK_SELF_ASSIGNED / LINK_MEDIA_MBPS / LINK_MEDIA_MAX_MBPS / LINK_DUPLEX.
# LINK_UP is 1 only when a device is BOTH active AND holds a *real*
# address: an active radio with no lease is associated but unconfigured,
# which is a fault worth naming, not a working link — and a self-assigned
# 169.254 address is the same fault wearing an address, so it does not
# count either. LINK_SELF_ASSIGNED records which of those two it was, so
# DH-3 can tell "nothing answered DHCP" from "no address at all".
#
# Writes globals read by lib/iface.sh, lib/diagnosis.sh and emit_json.py.
# shellcheck disable=SC2034
linkstate_run() {
  local preferred="${1:-}" devices dev out
  LINK_DEVICE=""; LINK_STATUS=""; LINK_IP=""; LINK_DHCP_ROUTER=""; LINK_UP=0
  LINK_SELF_ASSIGNED=0
  LINK_MEDIA_MBPS=""; LINK_MEDIA_MAX_MBPS=""; LINK_DUPLEX=""
  LINK_MEDIA_FULL_DUPLEX_CAPABLE=0

  devices="$preferred"
  # The service order is only read when the preferred device did not
  # settle it, because networksetup costs ~100 ms and the overwhelming
  # majority of runs have a default route.
  if [ -z "$preferred" ]; then
    devices="$(linkstate_parse_service_devices \
      "$(networksetup -listnetworkserviceorder 2>/dev/null || true)")"
  fi

  # The best unconfigured candidate seen so far, held aside rather than
  # written straight to LINK_*. An active device with no usable address is
  # still the best answer we have if nothing better turns up — "associated
  # but not configured" is exactly the failure N1c and DH-3 describe — but
  # it must not displace a later device that actually holds a lease.
  #
  # Only the FIRST such device is kept. `devices` is macOS's own priority
  # ranking, so when several are equally unconfigured the highest-ranked
  # one is the one the user thinks they are on. (Before self-assigned
  # addresses were recognised this loop overwrote LINK_DEVICE on every
  # active device, so the *last* one won — invisible while the only way to
  # reach the end of the loop was a machine with nothing configured at
  # all, and wrong the moment 169.254 addresses started arriving here.)
  local cand_dev="" cand_status="" cand_ip="" cand_router="" cand_self=0
  local cand_mbps="" cand_max="" cand_duplex="" cand_fd=0
  for dev in $devices; do
    # `-m` rather than a bare ifconfig: the output is a superset — same
    # status and inet lines — plus the `supported media:` block ETH-1
    # needs to know what the port is capable of. One subprocess, not two.
    out="$(ifconfig -m "$dev" 2>/dev/null || true)"
    [ -n "$out" ] || continue
    local dev_status dev_ip dev_router dev_mbps dev_max dev_duplex dev_fd
    dev_status="$(linkstate_parse_ifconfig_status "$out")"
    [ "$dev_status" = "active" ] || continue
    dev_ip="$(linkstate_parse_ifconfig_ip "$out")"
    dev_router="$(linkstate_parse_dhcp_router \
      "$(ipconfig getpacket "$dev" 2>/dev/null || true)")"
    dev_mbps="$(linkstate_parse_media_rate "$out")"
    dev_max="$(linkstate_parse_media_max "$out")"
    dev_duplex="$(linkstate_parse_media_duplex "$out")"
    dev_fd=0; linkstate_media_has_full_duplex "$out" && dev_fd=1

    # A real lease is the best possible answer; take it and stop looking.
    if [ -n "$dev_ip" ] && ! linkstate_is_link_local "$dev_ip"; then
      LINK_DEVICE="$dev"
      LINK_STATUS="$dev_status"
      LINK_IP="$dev_ip"
      LINK_DHCP_ROUTER="$dev_router"
      LINK_SELF_ASSIGNED=0
      LINK_MEDIA_MBPS="$dev_mbps"
      LINK_MEDIA_MAX_MBPS="$dev_max"
      LINK_DUPLEX="$dev_duplex"
      LINK_MEDIA_FULL_DUPLEX_CAPABLE="$dev_fd"
      LINK_UP=1
      return 0
    fi

    [ -z "$cand_dev" ] || continue
    cand_dev="$dev"; cand_status="$dev_status"; cand_ip="$dev_ip"
    cand_router="$dev_router"
    cand_mbps="$dev_mbps"; cand_max="$dev_max"; cand_duplex="$dev_duplex"
    cand_fd="$dev_fd"
    linkstate_is_link_local "$dev_ip" && cand_self=1
  done

  # Nothing held a lease. Report the best candidate, with LINK_UP left at
  # 0: a self-assigned address is macOS announcing that no DHCP server
  # answered, not connectivity, and calling it a configured link is how a
  # total DHCP failure came to be reported as a healthy network.
  LINK_DEVICE="$cand_dev"
  LINK_STATUS="$cand_status"
  LINK_IP="$cand_ip"
  LINK_DHCP_ROUTER="$cand_router"
  LINK_SELF_ASSIGNED="$cand_self"
  LINK_MEDIA_MBPS="$cand_mbps"
  LINK_MEDIA_MAX_MBPS="$cand_max"
  LINK_DUPLEX="$cand_duplex"
  LINK_MEDIA_FULL_DUPLEX_CAPABLE="$cand_fd"
  return 0
}
