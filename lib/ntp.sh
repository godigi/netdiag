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
  # sntp -t 3 dominates the parallel batch at ~3-5 s; skip under --quick
  # so the run hits its 8 s spec budget. Clock drift > 30 s is a critical
  # rule but the default mode catches it.
  [ "$QUICK" -eq 0 ] || { progress_skip "--quick"; return 0; }
  hdr "NTP / time sync"
  local ntp_out drift_abs
  ntp_out="$(with_timeout 5 sntp -t 3 time.apple.com 2>/dev/null || true)"
  if [ -n "$ntp_out" ]; then
    # sntp prints chatty debug when the first probe times out, then a real
    # result line. That line is NOT positionally stable: ntp 4.2.8 (what
    # macOS ships) normally prefixes the timestamp —
    #   "2026-08-07 12:00:00.123456 (+0000) +0.001234 +/- 0.012345 host ip"
    # — while some builds/invocations lead with the offset:
    #   "+0.001234 +/- 0.012345 time.apple.com 17.253.4.13"
    # Taking $1 grabs the *date* under the first format, which then sails
    # through the awk comparisons below as a string and reports a clock
    # "off by 2026-08-07 seconds". Anchor on the "+/-" token instead and
    # take the field immediately before it; last match wins, matching the
    # previous `tail -1` behaviour of skipping retry chatter.
    NTP_DRIFT_S="$(printf '%s\n' "$ntp_out" \
      | awk '{ for (i = 1; i < NF; i++) if ($(i+1) == "+/-") d = $i }
             END { if (d != "") print d }')"
    is_numeric "$NTP_DRIFT_S" || NTP_DRIFT_S=""
    if [ -n "$NTP_DRIFT_S" ]; then
      # Only surface the number when the clock is actually wrong enough to
      # cause problems. Sub-second drift is round-trip noise, not a real
      # condition users can act on. The diagnosis rule (NT-1) escalates
      # the > 30 s case to critical in its own section.
      drift_abs="$(awk -v d="$NTP_DRIFT_S" 'BEGIN{print (d<0)?-d:d}')"
      if awk -v d="$drift_abs" 'BEGIN{exit !(d > 30)}'; then
        bad "Clock is off by ${NTP_DRIFT_S}s — TLS handshakes will fail. Re-enable network time / NTP."
      elif awk -v d="$drift_abs" 'BEGIN{exit !(d > 1)}'; then
        warn "Clock is off by ${NTP_DRIFT_S}s — some apps and TLS validations may misbehave."
      else
        ok "Clock is synced."
      fi
    else
      info "sntp replied but its output didn't parse — skipping the clock check."
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
