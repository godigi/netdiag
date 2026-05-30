# shellcheck shell=bash
# lib/ipv6.sh — IPv6 parity checks: global address, ping6, AAAA, TCP/443.
#
# Reads:  INTERFACE
# Writes: IPV6_AVAILABLE, IPV6_GLOBAL_ADDR, IPV6_GATEWAY, IPV6_PING_LOSS,
#         IPV6_AAAA_OK, IPV6_TRACE_HOPS, IPV6_TCP_OK
# Entry:  ipv6_run
#
# Safe to run in parallel — doesn't contend on the WAN link materially.

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
    ping6_out="$(ping6 -c 5 -i 0.2 -W 2000 2606:4700:4700::1111 2>/dev/null || true)"
    IPV6_PING_LOSS="$(printf '%s\n' "$ping6_out" \
      | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
    IPV6_PING_LOSS="${IPV6_PING_LOSS:-100}"
    if [ "${IPV6_PING_LOSS%.*}" -eq 0 ]; then
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

    if command -v traceroute6 >/dev/null 2>&1; then
      IPV6_TRACE_HOPS="$(traceroute6 -n -q 1 -w 2 -m 12 2606:4700:4700::1111 2>/dev/null \
        | awk '/^[[:space:]]*[0-9]+/' | wc -l | tr -d ' ')"
      info "traceroute6: ${IPV6_TRACE_HOPS} hops to Cloudflare"
    fi

    if nc -6 -G 3 -z ipv6.google.com 443 2>/dev/null; then
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
