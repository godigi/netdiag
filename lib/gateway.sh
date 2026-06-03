# shellcheck shell=bash
# lib/gateway.sh — gateway reachability via 10× ICMP echo. Parses
# avg latency AND jitter (stddev from ping's summary line) so the
# Report card can flag unstable LAN links.
#
# Reads:  GATEWAY
# Writes: GW_LOSS, GW_LATENCY, GW_JITTER
# Entry:  gateway_run

gateway_run() {
  hdr "Gateway reachability"
  if [ -z "$GATEWAY" ]; then
    bad "No gateway to test."
    return 0
  fi
  # 10 packets in default mode for a stable jitter number; --quick halves
  # the count to keep the whole run inside the 8 s spec budget.
  local ping_out count=10
  [ "$QUICK" -eq 1 ] && count=5
  ping_out="$(ping -c "$count" -t 3 -i 0.2 "$GATEWAY" 2>&1)"
  printf '%s\n' "$ping_out" >> "$LOG"
  GW_LOSS="$(printf '%s\n' "$ping_out" | awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++)if($i=="packet")print $(i-2)}' | head -1)"
  # ping's summary: "round-trip min/avg/max/stddev = 3.024/3.485/4.197/0.305 ms"
  # Splitting by [ /] gives ... avg=NF-3, stddev (jitter)=NF-1.
  GW_LATENCY="$(printf '%s\n' "$ping_out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
  GW_JITTER="$(printf '%s\n' "$ping_out"  | awk -F'[ /]' '/round-trip|rtt/{print $(NF-1)}' | head -1)"
  GW_LOSS="${GW_LOSS:-100}"
  if [ "${GW_LOSS%.*}" -eq 0 ]; then
    ok "Gateway $GATEWAY: 0% loss · ${GW_LATENCY} ms avg · ±${GW_JITTER:-?} ms jitter"
  elif [ "${GW_LOSS%.*}" -lt 20 ]; then
    warn "Gateway $GATEWAY: ${GW_LOSS}% loss · ${GW_LATENCY} ms · ±${GW_JITTER:-?} ms jitter"
  else
    bad "Gateway $GATEWAY: ${GW_LOSS}% loss — LAN/WiFi link is degraded"
  fi
}
