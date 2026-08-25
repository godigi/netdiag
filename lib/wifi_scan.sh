# shellcheck shell=bash
# lib/wifi_scan.sh — WiFi neighborhood scan via system_profiler.
#
# system_profiler is the only remaining shell-callable WiFi scanner on
# modern macOS (airport(8) was retired; wdutil has no scan subcommand).
# It doesn't need sudo. Trade-off: it doesn't expose RSSI for *neighbour*
# APs, so we can only count channel utilisation, not compare signal
# strength.
#
# Reads:  IS_WIFI, QUICK
# Writes: WIFI_SCAN_CURRENT_CHANNEL, WIFI_SCAN_CURRENT_BAND,
#         WIFI_SCAN_NEIGHBOR_COUNT, WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS
# Entry:  wifi_scan_run

wifi_scan_run() {
  [ "$IS_WIFI" -eq 1 ] || { progress_skip "not on wifi"; return 0; }
  [ "$QUICK" -eq 0 ]   || { progress_skip "--quick"; return 0; }

  hdr "WiFi neighborhood"
  local sp_out
  # system_profiler can spend a surprisingly long time waiting on a stale
  # CoreWLAN service. A scan is optional, so it must not hold the whole
  # parallel batch open indefinitely.
  sp_out="$(with_timeout 15 system_profiler SPAirPortDataType -detailLevel full 2>/dev/null || true)"
  if [ -z "$sp_out" ]; then
    warn "system_profiler returned no WiFi data."
    return 0
  fi

  local sp_parsed neighbor_chans
  sp_parsed="$(printf '%s\n' "$sp_out" | awk '
    /Current Network Information:/{section="current"; next}
    /Other Local Wi-Fi Networks:/{section="other"; next}
    /^[A-Z]/ && section{section=""}
    /^[[:space:]]*Channel:[[:space:]]*[0-9]+/{
      match($0, /[0-9]+/); ch = substr($0, RSTART, RLENGTH)
      band = "?"
      if (match($0, /\(([^,]+)/)) band = substr($0, RSTART+1, RLENGTH-1)
      if (section=="current")    print "CURRENT\t" ch "\t" band
      else if (section=="other") print "OTHER\t"   ch "\t" band
    }')"
  WIFI_SCAN_CURRENT_CHANNEL="$(printf '%s' "$sp_parsed" | awk -F'\t' '$1=="CURRENT"{print $2; exit}')"
  WIFI_SCAN_CURRENT_BAND="$(printf '%s' "$sp_parsed"   | awk -F'\t' '$1=="CURRENT"{print $3; exit}')"
  neighbor_chans="$(printf '%s' "$sp_parsed" | awk -F'\t' '$1=="OTHER"{print $2}')"
  WIFI_SCAN_NEIGHBOR_COUNT="$(printf '%s' "$neighbor_chans" | grep -c . || true)"
  if [ -n "$WIFI_SCAN_CURRENT_CHANNEL" ]; then
    WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS="$(printf '%s' "$neighbor_chans" \
      | awk -v c="$WIFI_SCAN_CURRENT_CHANNEL" '$1==c{n++} END{print n+0}')"
  fi
  info "Current channel: ${WIFI_SCAN_CURRENT_CHANNEL:-?} (${WIFI_SCAN_CURRENT_BAND:-?})"
  info "Neighbours: $WIFI_SCAN_NEIGHBOR_COUNT total, $WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS on your channel"
  if [ "$WIFI_SCAN_NEIGHBOR_COUNT" -gt 0 ]; then
    info "Top neighbour channels:"
    printf '%s\n' "$neighbor_chans" | sort | uniq -c | sort -rn | head -5 \
      | awk '{printf "      ch %-4s × %d\n", $2, $1}' | log_pipe
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar WIFI_SCAN_CURRENT_CHANNEL "$WIFI_SCAN_CURRENT_CHANNEL"
    setvar WIFI_SCAN_CURRENT_BAND "$WIFI_SCAN_CURRENT_BAND"
    setvar WIFI_SCAN_NEIGHBOR_COUNT "$WIFI_SCAN_NEIGHBOR_COUNT"
    setvar WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS"
  fi
}
