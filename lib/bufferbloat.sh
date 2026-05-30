# shellcheck shell=bash
# lib/bufferbloat.sh — loaded-vs-idle latency probe via Cloudflare's
# /__down=100MB endpoint. Grades gateway and internet legs separately.
#
# This check loads the link with sustained traffic, so it MUST NOT overlap
# with other latency-sensitive checks — the orchestrator runs it
# sequentially, not as part of the parallel batch.
#
# Reads:  QUICK, NO_BUFFERBLOAT, GATEWAY, PUBLIC_OK, GW_LATENCY
# Writes: BUFFERBLOAT_IDLE_GW_RTT, BUFFERBLOAT_LOADED_GW_RTT,
#         BUFFERBLOAT_IDLE_INET_RTT, BUFFERBLOAT_LOADED_INET_RTT,
#         BUFFERBLOAT_GW_DELTA, BUFFERBLOAT_INET_DELTA,
#         BUFFERBLOAT_GW_GRADE, BUFFERBLOAT_INET_GRADE
# Entry:  bufferbloat_run

bufferbloat_run() {
  [ "$QUICK" -eq 0 ]          || return 0
  [ "$NO_BUFFERBLOAT" -eq 0 ] || return 0
  [ -n "$GATEWAY" ]           || return 0
  [ "$PUBLIC_OK" -eq 1 ]      || return 0

  hdr "Bufferbloat (loaded vs idle latency)"

  # Idle baseline: reuse gateway RTT from section 3; do a quick internet ping.
  local bb_idle_inet_out
  bb_idle_inet_out="$(ping -c 8 -t 2 -i 0.2 1.1.1.1 2>/dev/null || true)"
  BUFFERBLOAT_IDLE_INET_RTT="$(printf '%s\n' "$bb_idle_inet_out" \
    | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  BUFFERBLOAT_IDLE_GW_RTT="${GW_LATENCY:-}"

  if [ -z "$BUFFERBLOAT_IDLE_INET_RTT" ] || [ -z "$BUFFERBLOAT_IDLE_GW_RTT" ]; then
    warn "Skipping bufferbloat — idle baseline failed."
    return 0
  fi

  info "Idle:  gateway ${BUFFERBLOAT_IDLE_GW_RTT} ms · internet ${BUFFERBLOAT_IDLE_INET_RTT} ms"
  info "Loading link with 100 MB download for 10 s..."

  local bb_tmp bb_dl_pid bb_pg_pid bb_pi_pid
  bb_tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-bb.XXXXXX")"
  # Background: 100 MB download capped at 10 s wall-clock.
  curl -s -o /dev/null --max-time 10 \
    'https://speed.cloudflare.com/__down?bytes=104857600' \
    >/dev/null 2>&1 &
  bb_dl_pid=$!

  # Brief settle so the TCP slow-start ramps before we start sampling.
  sleep 0.5
  ping -c 45 -t 2 -i 0.2 "$GATEWAY" > "$bb_tmp/gw.ping" 2>/dev/null &
  bb_pg_pid=$!
  ping -c 45 -t 2 -i 0.2 1.1.1.1   > "$bb_tmp/inet.ping" 2>/dev/null &
  bb_pi_pid=$!
  wait "$bb_pg_pid" "$bb_pi_pid"
  # Reap the download (--max-time should have already ended it).
  wait "$bb_dl_pid" 2>/dev/null || true

  BUFFERBLOAT_LOADED_GW_RTT="$(awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}' "$bb_tmp/gw.ping")"
  BUFFERBLOAT_LOADED_INET_RTT="$(awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}' "$bb_tmp/inet.ping")"
  rm -rf "$bb_tmp"

  if [ -z "$BUFFERBLOAT_LOADED_GW_RTT" ] || [ -z "$BUFFERBLOAT_LOADED_INET_RTT" ]; then
    warn "Loaded ping returned no rtt summary — link likely saturated to the point of total loss."
    return 0
  fi

  BUFFERBLOAT_GW_DELTA="$(awk -v a="$BUFFERBLOAT_IDLE_GW_RTT" -v b="$BUFFERBLOAT_LOADED_GW_RTT" \
    'BEGIN{printf "%.1f", b-a}')"
  BUFFERBLOAT_INET_DELTA="$(awk -v a="$BUFFERBLOAT_IDLE_INET_RTT" -v b="$BUFFERBLOAT_LOADED_INET_RTT" \
    'BEGIN{printf "%.1f", b-a}')"
  BUFFERBLOAT_GW_GRADE="$(grade_bufferbloat "$BUFFERBLOAT_GW_DELTA")"
  BUFFERBLOAT_INET_GRADE="$(grade_bufferbloat "$BUFFERBLOAT_INET_DELTA")"

  # A well-behaved link can report a slightly negative delta (loaded median
  # happened to be lower than the 8-sample idle median). Clamp to 0 for the
  # display so "+-2.3 ms" doesn't look like a typo. Raw values stay in the
  # JSON so consumers see the honest measurement.
  local gw_disp inet_disp
  gw_disp="$(  awk -v d="$BUFFERBLOAT_GW_DELTA"   'BEGIN{printf "%.1f", (d+0 < 0) ? 0 : d+0}')"
  inet_disp="$(awk -v d="$BUFFERBLOAT_INET_DELTA" 'BEGIN{printf "%.1f", (d+0 < 0) ? 0 : d+0}')"
  info "Loaded: gateway ${BUFFERBLOAT_LOADED_GW_RTT} ms (+${gw_disp} ms) · internet ${BUFFERBLOAT_LOADED_INET_RTT} ms (+${inet_disp} ms)"
  local pair label grade
  for pair in "gateway:${BUFFERBLOAT_GW_GRADE}" "internet:${BUFFERBLOAT_INET_GRADE}"; do
    label="${pair%%:*}"; grade="${pair##*:}"
    case "$grade" in
      A|B) ok   "Bufferbloat (${label}): grade ${grade}" ;;
      C)   warn "Bufferbloat (${label}): grade ${grade} — noticeable under load" ;;
      D|F) bad  "Bufferbloat (${label}): grade ${grade} — VOIP/Zoom will glitch" ;;
    esac
  done
}
