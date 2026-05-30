# shellcheck shell=bash
# lib/ntp.sh — NTP / time-sync drift check via sntp.
#
# Wrong system time breaks TLS cert validation across the board; users see
# it as "the internet is broken" without any network-level fault to point at.
#
# Reads:  (nothing)
# Writes: NTP_DRIFT_S, NTP_USING_NETWORK_TIME, NTP_SERVER
# Entry:  ntp_run
#
# Safe to run in parallel — UDP/123 is light traffic.

ntp_run() {
  hdr "NTP / time sync"
  local ntp_out drift_abs
  ntp_out="$(with_timeout 5 sntp -t 3 time.apple.com 2>/dev/null || true)"
  if [ -n "$ntp_out" ]; then
    # sntp prints chatty debug when the first probe times out, then a real
    # result line like "+0.001234 +/- 0.012345 time.apple.com 17.253.4.13".
    # Filter to lines containing the +/- token to get just the result.
    NTP_DRIFT_S="$(printf '%s\n' "$ntp_out" | grep -F '+/-' | tail -1 | awk '{print $1}')"
    if [ -n "$NTP_DRIFT_S" ]; then
      info "sntp vs time.apple.com: ${NTP_DRIFT_S}s drift"
      drift_abs="$(awk -v d="$NTP_DRIFT_S" 'BEGIN{print (d<0)?-d:d}')"
      if awk -v d="$drift_abs" 'BEGIN{exit !(d > 30)}'; then
        bad "Clock drift > 30 s — TLS handshakes will fail. Re-enable network time / NTP."
      else
        ok "Clock drift within tolerance."
      fi
    fi
  else
    warn "sntp returned no result (firewall blocking UDP/123?)."
  fi
  # Network time settings — getters need root on Tahoe; try -n, skip on failure.
  if sudo -n true 2>/dev/null; then
    NTP_USING_NETWORK_TIME="$(sudo -n systemsetup -getusingnetworktime 2>/dev/null \
      | sed 's/^Network Time: //')"
    NTP_SERVER="$(sudo -n systemsetup -getnetworktimeserver 2>/dev/null \
      | sed 's/^Network Time Server: //')"
    [ -n "$NTP_USING_NETWORK_TIME" ] && info "Network time: $NTP_USING_NETWORK_TIME"
    [ -n "$NTP_SERVER" ]             && info "Network time server: $NTP_SERVER"
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar NTP_DRIFT_S "$NTP_DRIFT_S"
    setvar NTP_USING_NETWORK_TIME "$NTP_USING_NETWORK_TIME"
    setvar NTP_SERVER "$NTP_SERVER"
  fi
}
