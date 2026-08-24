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
  # 20 packets in default mode: enough for a stable jitter number, and it
  # puts the loss quantum at 5% so G3's warn band starts at a clean two
  # dropped packets. At the previous 10 packets the quantum was 10% and
  # the band could not distinguish one drop from two. Interval and count
  # come from the shared LOSS_PROBE_* constants so the gateway and the
  # internet probes can't drift apart; --quick halves the count to hold
  # the 8 s budget.
  #
  # No -t: on macOS it is a deadline for the whole run, so `-c 20 -t 3`
  # transmitted only as many packets as fit in 3 seconds and reported loss
  # over that truncated count. See lib/internet_ping.sh for the numbers.
  local ping_out parsed count="$LOSS_PROBE_COUNT"
  [ "$QUICK" -eq 1 ] && count="$THRESH_GATEWAY_QUICK_PING_COUNT"
  ping_out="$(with_timeout 15 ping -c "$count" -i "$LOSS_PROBE_INTERVAL" "$GATEWAY" 2>&1)"
  printf '%s\n' "$ping_out" >> "$LOG"
  parsed="$(ping_parse_summary "$ping_out")"
  IFS='|' read -r GW_LOSS GW_LATENCY GW_JITTER <<<"$parsed"
  # No summary means the probe did not measure loss. Keep it empty so the
  # diagnosis layer cannot turn a command failure into a confident 100%
  # loss claim.
  if [ -z "$GW_LOSS" ]; then
    warn "Gateway $GATEWAY: no packet-loss summary — loss unknown."
    return 0
  fi
  # Thresholds shared with the G1/G2/G3 rules so this line and the
  # diagnosis below it can never disagree. A single dropped packet (5%)
  # stays "ok": it is within the probe's own noise floor, and calling it
  # a warning here while G3 stays silent is the mismatch that made the
  # Report card and the diagnosis section contradict each other.
  if ! loss_at_least "$GW_LOSS" "$LOSS_WARN_PCT"; then
    ok "Gateway $GATEWAY: ${GW_LOSS}% loss · ${GW_LATENCY} ms avg · ±${GW_JITTER:-?} ms jitter"
  elif ! loss_at_least "$GW_LOSS" "$LOSS_CRIT_PCT"; then
    warn "Gateway $GATEWAY: ${GW_LOSS}% loss · ${GW_LATENCY} ms · ±${GW_JITTER:-?} ms jitter"
  else
    bad "Gateway $GATEWAY: ${GW_LOSS}% loss — LAN/WiFi link is degraded"
  fi
}
