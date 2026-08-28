# shellcheck shell=bash
# lib/ipv6.sh — IPv6 parity checks: global address, ping6, AAAA, TCP/443.
#
# Reads:  INTERFACE, QUICK
# Writes: IPV6_AVAILABLE, IPV6_GLOBAL_ADDR, IPV6_GATEWAY, IPV6_PING_LOSS,
#         IPV6_AAAA_OK, IPV6_TRACE_HOPS, IPV6_TCP_OK, IPV6_ONLY,
#         IPV6_CLAT
# Entry:  ipv6_run
#
# Safe to run in parallel — doesn't contend on the WAN link materially.

# Pull the loss percentage out of a ping6 summary. Returns empty — never a
# number — when there is no statistics line to read, so callers can tell
# "the probe failed" apart from "the probe measured total loss".
ipv6_parse_ping_loss() {
  local parsed
  parsed="$(ping_parse_summary "$1")"
  printf '%s\n' "${parsed%%|*}"
}

ipv6_run() {
  hdr "IPv6"
  if [ -n "$INTERFACE" ]; then
    IPV6_GLOBAL_ADDR="$(ifconfig "$INTERFACE" inet6 2>/dev/null \
      | awk '/inet6 / && !/fe80::/ && !/::1/ && !/%/ {print $2; exit}')"
  fi
  if [ -z "$IPV6_GLOBAL_ADDR" ]; then
    info "No global IPv6 on $INTERFACE — v4-only network."
  else
    IPV6_AVAILABLE=1
    ok "Global IPv6: $IPV6_GLOBAL_ADDR"
    IPV6_GATEWAY="$(route -n get -inet6 default 2>/dev/null | awk '/gateway:/{print $2}')"
    [ -n "$IPV6_GATEWAY" ] && info "v6 default route: $IPV6_GATEWAY"

    local ping6_out aaaa
    # No -W here. Unlike ping(8) and Linux's ping, macOS ping6's -W is a
    # *boolean* — it sits in the [-DdfHmnNoqrRtvwW] cluster and selects the
    # old 03-draft node-information packet format. Passing "-W 2000" made
    # ping6 read 2000 as the hostname, so it exited with "nodename nor
    # servname provided" before sending a single packet. 2>/dev/null hid the
    # message and the empty result was defaulted to 100% loss, so every
    # IPv6-capable machine reported a permanently broken IPv6 stack.
    # with_timeout supplies the wall-clock bound -W was meant to provide.
    ping6_out="$(with_timeout 6 ping6 -c 5 -i 0.2 2606:4700:4700::1111 2>/dev/null || true)"
    IPV6_PING_LOSS="$(ipv6_parse_ping_loss "$ping6_out")"
    if [ -z "$IPV6_PING_LOSS" ]; then
      # Empty means the measurement itself failed, which is not evidence
      # that IPv6 is down. Report it as unknown and let the AAAA and TCP6
      # probes speak: V6-1 and the Report card both treat "" as no data.
      warn "ping6 to 2606:4700:4700::1111 returned no statistics — IPv6 loss unknown."
    elif [ "${IPV6_PING_LOSS%.*}" -eq 0 ]; then
      ok "ping6 2606:4700:4700::1111: 0% loss"
    else
      bad "ping6 2606:4700:4700::1111: ${IPV6_PING_LOSS}% loss"
    fi

    aaaa="$(with_timeout 3 dig +time=2 +tries=1 +short AAAA cloudflare.com @1.1.1.1 2>/dev/null | head -1)"
    if [ -n "$aaaa" ]; then
      IPV6_AAAA_OK=1
      ok "AAAA cloudflare.com → $aaaa"
    else
      bad "AAAA cloudflare.com FAILED"
    fi

    # Skipped under --quick, and bounded in every mode.
    #
    # This one call was 7.4 s of --quick's 10.6 s — 70% of the wall clock
    # of the mode whose entire purpose is a fast "is it up?" answer. What
    # it produces is a hop count that feeds NO diagnosis rule:
    # IPV6_TRACE_HOPS reaches the JSON and a single info line that default
    # compact output doesn't even print. Paying seven seconds for it in
    # the fast path was the wrong trade.
    #
    # The with_timeout applies in full runs too, not just --quick. -m 12
    # hops at -w 2 s each is a 24 s worst case on a path that black-holes
    # IPv6, and this was the only probe in the module with no wall-clock
    # bound at all — ping6, dig and nc are all capped. An unbounded probe
    # that can silently dominate a run is the same shape as the ping -t
    # bug fixed in v0.6.0.
    #
    # Left empty when skipped, which _maybe_int renders as JSON null:
    # "not measured", never a fabricated 0.
    if [ "$QUICK" -eq 0 ] && command -v traceroute6 >/dev/null 2>&1; then
      IPV6_TRACE_HOPS="$(with_timeout 8 traceroute6 -n -q 1 -w 2 -m 12 2606:4700:4700::1111 2>/dev/null \
        | awk '/^[[:space:]]*[0-9]+/' | wc -l | tr -d ' ')"
      info "traceroute6: ${IPV6_TRACE_HOPS} hops to Cloudflare"
    fi

    if with_timeout 5 nc -6 -G 3 -z ipv6.google.com 443 2>/dev/null; then
      IPV6_TCP_OK=1
      ok "TCP/443 to ipv6.google.com: reachable"
    else
      bad "TCP/443 to ipv6.google.com: failed"
    fi
  fi

  # Is this network IPv6-only *by design*? Decided here rather than in
  # diagnosis.sh so the answer travels with the other IPv6 facts, and so
  # the CLAT address is read while INTERFACE is still in scope. [V6-3]
  IPV6_CLAT=0
  if [ -n "$INTERFACE" ]; then
    local _v4
    _v4="$(ifconfig "$INTERFACE" inet 2>/dev/null \
      | awk '$1=="inet"{print $2; exit}')"
    ipv6_is_clat_address "$_v4" && IPV6_CLAT=1
  fi
  IPV6_ONLY=0
  ipv6_is_v6_only "$IPV6_AVAILABLE" "$IPV6_AAAA_OK" "$IPV6_TCP_OK" \
    "${GATEWAY:-}" && IPV6_ONLY=1

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar IPV6_AVAILABLE "$IPV6_AVAILABLE"
    setvar IPV6_GLOBAL_ADDR "$IPV6_GLOBAL_ADDR"
    setvar IPV6_GATEWAY "$IPV6_GATEWAY"
    setvar IPV6_PING_LOSS "$IPV6_PING_LOSS"
    setvar IPV6_AAAA_OK "$IPV6_AAAA_OK"
    setvar IPV6_TRACE_HOPS "$IPV6_TRACE_HOPS"
    setvar IPV6_TCP_OK "$IPV6_TCP_OK"
    setvar IPV6_ONLY "$IPV6_ONLY"
    setvar IPV6_CLAT "$IPV6_CLAT"
  fi
}

# ── IPv6-only networks with NAT64/DNS64 [V6-3] ───────────────────────────
#
# V6-1 covers broken IPv6 alongside working IPv4. This is the mirror, and
# until now it did not exist: on a network that is IPv6-only *by design*
# — some mobile carriers, some university and enterprise networks, a
# growing share of new deployments — there is no IPv4 at all, and macOS
# translates via 464XLAT.
#
# netdiag's GATEWAY comes from `route -n get default`, which is IPv4. So
# an IPv6-only network leaves it empty, and the run falls into N1 ("no
# network connection at all") or N1c ("joined with no route out") — both
# critical, both false, on a network that is working exactly as intended
# and carrying the user's traffic perfectly well.

# True when $1 is a CLAT address from 192.0.0.0/29 — the range RFC 7335
# reserves for the IPv4 side of a 464XLAT translator.
#
# macOS synthesises one of these on an IPv6-only network so IPv4-only
# apps keep working. It is not a lease from any DHCP server and there is
# no IPv4 network behind it, which is why it must not be read as one.
#
# Matched on the full /29 rather than the /24, because 192.0.0.8 and up
# are IETF protocol assignments, not translator addresses.
ipv6_is_clat_address() {
  case "${1:-}" in
    192.0.0.[0-7]) return 0 ;;
    *)             return 1 ;;
  esac
}

# True when the network is IPv6-only and working: $1 = IPV6_AVAILABLE,
# $2 = IPV6_AAAA_OK, $3 = IPV6_TCP_OK, $4 = the IPv4 GATEWAY.
#
# Deliberately demands that IPv6 be *proven* — a global address alone is
# not enough, since V6-1 exists precisely because a half-configured IPv6
# stack is common. A real TCP connection over IPv6 plus a working AAAA
# lookup is the evidence that this network carries traffic; without both,
# an absent IPv4 gateway is a genuine outage and N1/N1c should say so.
ipv6_is_v6_only() {
  [ "${1:-0}" -eq 1 ] || return 1
  [ "${2:-0}" -eq 1 ] || return 1
  [ "${3:-0}" -eq 1 ] || return 1
  [ -z "${4:-}" ]     || return 1
  return 0
}
