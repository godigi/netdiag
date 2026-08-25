# shellcheck shell=bash
# lib/ipv6.sh — IPv6 parity checks: global address, ping6, AAAA, TCP/443.
#
# Reads:  INTERFACE, QUICK
# Writes: IPV6_AVAILABLE, IPV6_GLOBAL_ADDR, IPV6_GATEWAY, IPV6_PING_LOSS,
#         IPV6_AAAA_OK, IPV6_TRACE_HOPS, IPV6_TCP_OK
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

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar IPV6_AVAILABLE "$IPV6_AVAILABLE"
    setvar IPV6_GLOBAL_ADDR "$IPV6_GLOBAL_ADDR"
    setvar IPV6_GATEWAY "$IPV6_GATEWAY"
    setvar IPV6_PING_LOSS "$IPV6_PING_LOSS"
    setvar IPV6_AAAA_OK "$IPV6_AAAA_OK"
    setvar IPV6_TRACE_HOPS "$IPV6_TRACE_HOPS"
    setvar IPV6_TCP_OK "$IPV6_TCP_OK"
  fi
}
