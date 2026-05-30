# shellcheck shell=bash
# lib/wifi_disconnect.sh — WiFi disconnect / roam history from `log show`.
#
# Queries the user's own log database — no sudo needed for these subsystems.
# Skipped under --quick because `log show --last 1h` takes ~3 s.
#
# Reads:  IS_WIFI, QUICK, WIFI_DISCONNECT_WINDOW_HOURS
# Writes: WIFI_DISCONNECT_COUNT
# Entry:  wifi_disconnect_run

wifi_disconnect_run() {
  [ "$IS_WIFI" -eq 1 ] || return 0
  [ "$QUICK" -eq 0 ]   || return 0

  hdr "WiFi disconnects (past ${WIFI_DISCONNECT_WINDOW_HOURS}h)"
  local wifi_log_out
  wifi_log_out="$(log show \
      --predicate 'subsystem CONTAINS[c] "wifi" OR subsystem CONTAINS[c] "airport"' \
      --info --last "${WIFI_DISCONNECT_WINDOW_HOURS}h" 2>/dev/null \
    | grep -Ei 'association|disassoc|deauth|roam|link down|link up' || true)"
  # Count only event lines, not `disassoc=...` substrings inside dictionary
  # dumps. Match the canonical past-tense verbs and other unambiguous tokens.
  WIFI_DISCONNECT_COUNT="$(printf '%s' "$wifi_log_out" \
    | grep -Eic '(disassociated|deauthenticated|link[[:space:]]+down|disconnect[[:space:]]+reason|reassociating)' \
    || true)"
  WIFI_DISCONNECT_COUNT="${WIFI_DISCONNECT_COUNT:-0}"
  info "Disconnect/reassoc events in last hour: $WIFI_DISCONNECT_COUNT"
  # Only show event detail when there were actual disconnects — otherwise the
  # 2KB-per-line airportd dumps drown out the rest of the report. Each event
  # is condensed to "YYYY-MM-DD HH:MM:SS  <message after airportd:>",
  # truncated to 120 chars.
  if [ "$WIFI_DISCONNECT_COUNT" -gt 0 ]; then
    info "Recent disconnect events:"
    printf '%s\n' "$wifi_log_out" \
      | grep -Ei '(disassociated|deauthenticated|link[[:space:]]+down|disconnect[[:space:]]+reason|reassociating)' \
      | tail -5 \
      | awk '{
          ts = $1 " " $2
          sub(/\..*/, "", ts)
          idx = index($0, "airportd")
          if (idx > 0) {
            msg = substr($0, idx)
            sub(/^airportd[^:]*:[[:space:]]*/, "", msg)
          } else {
            msg = $0
          }
          line = ts "  " msg
          if (length(line) > 120) line = substr(line, 1, 119) "…"
          print "      " line
        }' \
      | log_pipe
  fi
  if [ "$WIFI_DISCONNECT_COUNT" -gt 3 ]; then
    warn "WiFi link is flapping ($WIFI_DISCONNECT_COUNT disconnects in 1h)."
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar WIFI_DISCONNECT_COUNT "$WIFI_DISCONNECT_COUNT"
  fi
}
