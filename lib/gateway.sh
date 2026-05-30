# shellcheck shell=bash
# lib/gateway.sh — gateway reachability via 10× ICMP echo.
#
# Reads:  GATEWAY
# Writes: GW_LOSS, GW_LATENCY
# Entry:  gateway_run

gateway_run() {
  hdr "Gateway reachability"
  if [ -z "$GATEWAY" ]; then
    bad "No gateway to test."
    return 0
  fi
  local ping_out
  ping_out="$(ping -c 10 -t 3 -i 0.2 "$GATEWAY" 2>&1)"
  printf '%s\n' "$ping_out" >> "$LOG"
  GW_LOSS="$(printf '%s\n' "$ping_out" | awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++)if($i=="packet")print $(i-2)}' | head -1)"
  GW_LATENCY="$(printf '%s\n' "$ping_out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
  GW_LOSS="${GW_LOSS:-100}"
  if [ "${GW_LOSS%.*}" -eq 0 ]; then
    ok "Gateway $GATEWAY: 0% loss, ${GW_LATENCY} ms avg"
  elif [ "${GW_LOSS%.*}" -lt 20 ]; then
    warn "Gateway $GATEWAY: ${GW_LOSS}% loss, ${GW_LATENCY} ms"
  else
    bad "Gateway $GATEWAY: ${GW_LOSS}% loss — LAN/WiFi link is degraded"
  fi
}
