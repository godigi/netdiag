# shellcheck shell=bash
# lib/speedtest.sh — speed test via Ookla `speedtest`, falling back to
# `speedtest-cli`. Sequenced after bufferbloat so the two don't compete
# for the link.
#
# Reads:  SPEED, NO_SPEED, PUBLIC_OK
# Writes: SPEEDTEST_DOWN_MBPS, SPEEDTEST_UP_MBPS, SPEEDTEST_LATENCY_MS,
#         SPEEDTEST_JITTER_MS, SPEEDTEST_SERVER
# Entry:  speedtest_run

speedtest_run() {
  [ "$SPEED" -eq 1 ]     || return 0
  [ "$NO_SPEED" -eq 0 ]  || return 0
  [ "$PUBLIC_OK" -eq 1 ] || return 0

  hdr "Speed test"
  local st_out
  if command -v speedtest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    info "Running Ookla speedtest..."
    st_out="$(speedtest --format=json --accept-license --accept-gdpr 2>/dev/null || true)"
    if [ -n "$st_out" ] && printf '%s' "$st_out" | jq -e .download.bandwidth >/dev/null 2>&1; then
      SPEEDTEST_DOWN_MBPS="$(printf '%s' "$st_out" | jq -r '.download.bandwidth * 8 / 1000000' | awk '{printf "%.1f", $1}')"
      SPEEDTEST_UP_MBPS="$(  printf '%s' "$st_out" | jq -r '.upload.bandwidth   * 8 / 1000000' | awk '{printf "%.1f", $1}')"
      SPEEDTEST_LATENCY_MS="$(printf '%s' "$st_out" | jq -r '.ping.latency')"
      SPEEDTEST_JITTER_MS="$( printf '%s' "$st_out" | jq -r '.ping.jitter')"
      SPEEDTEST_SERVER="$(    printf '%s' "$st_out" | jq -r '.server.name')"
      ok "Down ${SPEEDTEST_DOWN_MBPS} Mbps · Up ${SPEEDTEST_UP_MBPS} Mbps · ${SPEEDTEST_LATENCY_MS} ms (jitter ${SPEEDTEST_JITTER_MS} ms)"
      info "Server: $SPEEDTEST_SERVER"
    else
      warn "Ookla speedtest failed or returned unparseable output."
    fi
  elif command -v speedtest-cli >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    info "Running speedtest-cli..."
    st_out="$(speedtest-cli --json 2>/dev/null || true)"
    if [ -n "$st_out" ] && printf '%s' "$st_out" | jq -e .download >/dev/null 2>&1; then
      SPEEDTEST_DOWN_MBPS="$(printf '%s' "$st_out" | jq -r '.download / 1000000' | awk '{printf "%.1f", $1}')"
      SPEEDTEST_UP_MBPS="$(  printf '%s' "$st_out" | jq -r '.upload   / 1000000' | awk '{printf "%.1f", $1}')"
      SPEEDTEST_LATENCY_MS="$(printf '%s' "$st_out" | jq -r '.ping')"
      SPEEDTEST_SERVER="$(   printf '%s' "$st_out" | jq -r '.server.host')"
      ok "Down ${SPEEDTEST_DOWN_MBPS} Mbps · Up ${SPEEDTEST_UP_MBPS} Mbps · ${SPEEDTEST_LATENCY_MS} ms"
      info "Server: $SPEEDTEST_SERVER"
    else
      warn "speedtest-cli failed or returned unparseable output."
    fi
  else
    warn "No speedtest CLI installed. Install with: brew install speedtest (Ookla) or brew install speedtest-cli."
  fi
}
