# shellcheck shell=bash
# lib/internet_ping.sh — ICMP probes to two independent public anycast
# resolvers to capture internet-side latency, jitter (ping stddev), and
# loss. Cheap (~2 s) so it always runs outside --quick, in the parallel
# batch.
#
# Reads:  INET_TARGET, INET_TARGET_ALT
# Writes: INET_RTT_AVG, INET_RTT_JITTER, INET_LOSS,
#         INET_RTT_AVG_ALT, INET_LOSS_ALT
# Entry:  internet_ping_run
#
# Why 20 packets and not the original 8: the loss percentage a probe can
# express is quantised by its packet count. At 8 packets one drop reads as
# 12.5%, so no threshold below that was expressible at all. 20 packets
# puts the quantum at 5%, which lets the thresholds in lib/globals.sh sit
# at a whole number of dropped packets (2 to warn, 4 to escalate).
#
# Why two targets: 1.1.1.1 and 8.8.8.8 both rate-limit ICMP, so a single
# lossy target is as likely to be that operator's policy as the user's
# network. L1 escalates to critical only when both agree; either one alone
# caps out at L2's warning.
#
# ── Why there is no -t flag here ─────────────────────────────────────────
# On macOS, ping's -t is "exit after this many seconds regardless of how
# many packets have been sent" — a deadline for the entire run. It is NOT
# a per-packet TTL or reply timeout, which is what the old `-c 8 -t 2`
# looked like it meant. The consequences were measured:
#
#   ping -c 20 -i 0.2 -t 2   →  10 packets transmitted   (half the probe
#                                silently discarded; the loss quantum
#                                becomes 10%, not the intended 5%)
#   ping -c 20 -i 0.1 -t 2   →  20 transmitted, 19 received, "5.0% loss"
#                                (the last reply lands after the deadline
#                                and is counted as a drop)
#   ping -c 20 -i 0.1        →  20/20, 0.0% loss, every trial, both targets
#   ping -c 20 -i 0.2        →  20/20, 0.0% loss, every trial, both targets
#
# So a healthy link reported a permanent 5% loss floor, and the probe that
# was supposed to send 20 packets sent 10. Both artefacts were the flag,
# not the network. with_timeout supplies the outer bound instead, sized
# generously enough that it only fires on a genuinely stuck probe.
#
# Why this runs serially rather than in the parallel batch: measuring loss
# while DNS, TCP, NTP, the WiFi scan and two WAN checks all compete for the
# same interface is measuring the tool, not the network. The first full run
# with the probe in the batch reported 30% loss on a link an isolated probe
# showed to be clean — most of that was the -t truncation above, but the
# methodology is wrong regardless, and this number now decides a critical
# diagnosis. 4 s on a quiet link is worth it.

# Parse ping's summary into "<loss>|<avg>|<jitter>". Returns empty fields
# rather than defaults when the summary is missing: "the probe failed" and
# "the probe measured total loss" are different facts, and conflating them
# is what made ping6 report a permanently broken IPv6 stack in v0.5.1.
internet_ping_parse() {
  local out="$1" loss avg jitter
  loss="$(printf '%s\n' "$out" \
    | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
  # "round-trip min/avg/max/stddev = 3.024/3.485/4.197/0.305 ms"
  # Split on [ /] puts avg at NF-3 and stddev at NF-1.
  avg="$(printf    '%s\n' "$out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  jitter="$(printf '%s\n' "$out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-1); exit}')"
  printf '%s|%s|%s' "$loss" "$avg" "$jitter"
}

internet_ping_run() {
  # --quick budget: the gateway-side ping already gives a latency number;
  # skip the 2 s internet probe.
  [ "$QUICK" -eq 0 ] || { progress_skip "--quick"; return 0; }
  hdr "Internet latency"

  # Both targets probed concurrently, so wall-clock is one probe's worth
  # (~2 s) rather than two. Temp files rather than command substitution
  # because this function is itself already inside a launch_parallel
  # subshell, where setvar is the only channel back to the orchestrator.
  local tmp_a tmp_b
  tmp_a="$(mktemp -t netdiag-ping-a)"
  tmp_b="$(mktemp -t netdiag-ping-b)"
  # No -t. On macOS, ping's -t is a deadline for the WHOLE run, not a
  # per-packet TTL — see the header comment. with_timeout provides the
  # outer bound instead, generously, so it only ever fires on a genuinely
  # stuck probe rather than truncating a healthy one.
  with_timeout 15 ping -c "$LOSS_PROBE_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    "$INET_TARGET"     >"$tmp_a" 2>/dev/null &
  local pid_a=$!
  with_timeout 15 ping -c "$LOSS_PROBE_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    "$INET_TARGET_ALT" >"$tmp_b" 2>/dev/null &
  local pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  local parsed
  parsed="$(internet_ping_parse "$(cat "$tmp_a" 2>/dev/null)")"
  INET_LOSS="${parsed%%|*}"
  INET_RTT_AVG="$(printf '%s' "$parsed" | cut -d'|' -f2)"
  INET_RTT_JITTER="${parsed##*|}"

  parsed="$(internet_ping_parse "$(cat "$tmp_b" 2>/dev/null)")"
  INET_LOSS_ALT="${parsed%%|*}"
  INET_RTT_AVG_ALT="$(printf '%s' "$parsed" | cut -d'|' -f2)"

  rm -f "$tmp_a" "$tmp_b"

  if [ -n "$INET_RTT_AVG" ]; then
    info "Round-trip to ${INET_TARGET}: ${INET_RTT_AVG} ms avg · ±${INET_RTT_JITTER:-?} ms jitter · ${INET_LOSS:-?}% loss"
  else
    warn "ping to ${INET_TARGET} returned no summary — internet-side loss unknown for this target."
  fi
  if [ -n "$INET_RTT_AVG_ALT" ]; then
    info "Round-trip to ${INET_TARGET_ALT}: ${INET_RTT_AVG_ALT} ms avg · ${INET_LOSS_ALT:-?}% loss"
  else
    warn "ping to ${INET_TARGET_ALT} returned no summary — internet-side loss unknown for this target."
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar INET_RTT_AVG     "$INET_RTT_AVG"
    setvar INET_RTT_JITTER  "$INET_RTT_JITTER"
    setvar INET_LOSS        "$INET_LOSS"
    setvar INET_RTT_AVG_ALT "$INET_RTT_AVG_ALT"
    setvar INET_LOSS_ALT    "$INET_LOSS_ALT"
  fi
}
