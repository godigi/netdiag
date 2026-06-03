# shellcheck shell=bash
# lib/internet_ping.sh — 8-packet ICMP probe to 1.1.1.1 to capture
# internet-side latency, jitter (ping stddev), and loss. Cheap (~1-2 s)
# so always runs, in the parallel batch.
#
# Reads:  (nothing)
# Writes: INET_RTT_AVG, INET_RTT_JITTER, INET_LOSS
# Entry:  internet_ping_run
#
# Parallel-safe — only sends 8 small ICMP packets, doesn't load the link.

internet_ping_run() {
  # --quick budget: the gateway-side ping already gives a latency number;
  # skip the 1-2 s internet probe.
  [ "$QUICK" -eq 0 ] || return 0
  hdr "Internet latency"
  local ping_out
  ping_out="$(with_timeout 5 ping -c 8 -t 2 -i 0.1 1.1.1.1 2>/dev/null || true)"
  if [ -z "$ping_out" ]; then
    warn "Could not reach 1.1.1.1 for the latency probe."
    if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
      setvar INET_RTT_AVG ""
      setvar INET_RTT_JITTER ""
      setvar INET_LOSS "100"
    fi
    return 0
  fi
  INET_LOSS="$(printf '%s\n' "$ping_out" \
    | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
  INET_RTT_AVG="$(printf '%s\n' "$ping_out" \
    | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  INET_RTT_JITTER="$(printf '%s\n' "$ping_out" \
    | awk -F'[ /]' '/round-trip|rtt/{print $(NF-1); exit}')"
  INET_LOSS="${INET_LOSS:-0}"

  if [ -n "$INET_RTT_AVG" ]; then
    info "Round-trip to 1.1.1.1: ${INET_RTT_AVG} ms avg · ±${INET_RTT_JITTER:-?} ms jitter · ${INET_LOSS}% loss"
  else
    warn "ping to 1.1.1.1 returned no summary."
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar INET_RTT_AVG "$INET_RTT_AVG"
    setvar INET_RTT_JITTER "$INET_RTT_JITTER"
    setvar INET_LOSS "$INET_LOSS"
  fi
}
