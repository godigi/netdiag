# shellcheck shell=bash
# lib/wifi.sh — WiFi info: SSID/BSSID/security via ipconfig getsummary,
# plus RSSI/noise/channel/PHY/tx-rate via wdutil (which needs cached sudo).
#
# Reads:  INTERFACE
# Writes: IS_WIFI, WIFI_SSID, WIFI_BSSID, WIFI_SEC, WIFI_RSSI, WIFI_NOISE,
#         WIFI_SNR, WIFI_CHAN, WIFI_PHY, WIFI_TX
# Entry:  wifi_run

# Writes IS_WIFI, WIFI_* — read by diagnosis.sh / output.sh / emit_json.py.
# shellcheck disable=SC2034
wifi_run() {
  hdr "WiFi"
  IS_WIFI=0
  WIFI_CHECKED=1
  # Detect WiFi via hardware port type (more reliable than networksetup
  # -getairportnetwork, which is broken on some macOS versions and falsely
  # reports "not associated").
  if [ -n "$INTERFACE" ]; then
    local hw_port
    hw_port="$(networksetup -listallhardwareports 2>/dev/null | awk -v d="$INTERFACE" '
      /^Hardware Port:/{port=substr($0, index($0,$3))}
      /^Device:/{if($2==d){print port; exit}}')"
    if printf '%s' "$hw_port" | grep -qi 'Wi-Fi\|AirPort'; then
      IS_WIFI=1
      # Pull SSID from ipconfig getsummary (works without sudo on modern macOS).
      local summary
      summary="$(ipconfig getsummary "$INTERFACE" 2>/dev/null)"
      WIFI_SSID="$(printf '%s\n' "$summary"  | awk -F': ' '/^[[:space:]]*SSID[[:space:]]*:/{print $2; exit}')"
      WIFI_BSSID="$(printf '%s\n' "$summary" | awk -F': ' '/^[[:space:]]*BSSID[[:space:]]*:/{print $2; exit}')"
      WIFI_SEC="$(printf '%s\n' "$summary"   | awk -F': ' '/^[[:space:]]*Security[[:space:]]*:/{print $2; exit}')"
      ok "SSID: ${WIFI_SSID:-?}  (interface $INTERFACE)"
      [ -n "$WIFI_BSSID" ] && info "BSSID: $WIFI_BSSID"
      [ -n "$WIFI_SEC" ]   && info "Security: $WIFI_SEC"
    fi
  fi
  if [ "$IS_WIFI" -eq 1 ]; then
    # Try wdutil for rich info (needs sudo). Non-interactive: only attempt if
    # cached creds.
    local wdutil_out=""
    if sudo -n true 2>/dev/null; then
      wdutil_out="$(sudo -n wdutil info 2>/dev/null)"
    fi

    if [ -n "$wdutil_out" ]; then
      local rssi noise wdutil_ssid wdutil_bssid
      # wdutil's SSID/BSSID is unredacted *if* the calling process has
      # Wi-Fi-access entitlement (Terminal with Location Services granted).
      # Override the ipconfig values when wdutil gave us something real.
      wdutil_ssid="$(printf '%s\n' "$wdutil_out"  | awk -F': ' '/^[[:space:]]*SSID[[:space:]]*:/{
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
      wdutil_bssid="$(printf '%s\n' "$wdutil_out" | awk -F': ' '/^[[:space:]]*BSSID[[:space:]]*:/{
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
      if [ -n "$wdutil_ssid" ] && [ "$wdutil_ssid" != "<redacted>" ]; then
        WIFI_SSID="$wdutil_ssid"
      fi
      if [ -n "$wdutil_bssid" ] && [ "$wdutil_bssid" != "<redacted>" ]; then
        WIFI_BSSID="$wdutil_bssid"
      fi
      rssi="$(printf '%s\n' "$wdutil_out"   | awk -F': ' '/^[[:space:]]*RSSI/{gsub(/ dBm/,"",$2); print $2; exit}')"
      noise="$(printf '%s\n' "$wdutil_out"  | awk -F': ' '/^[[:space:]]*Noise/{gsub(/ dBm/,"",$2); print $2; exit}')"
      WIFI_CHAN="$(printf '%s\n' "$wdutil_out"   | awk -F': ' '/^[[:space:]]*Channel/{print $2; exit}')"
      WIFI_TX="$(printf '%s\n'   "$wdutil_out"   | awk -F': ' '/Tx Rate/{print $2; exit}')"
      WIFI_PHY="$(printf '%s\n'  "$wdutil_out"   | awk -F': ' '/PHY Mode/{print $2; exit}')"
      # wdutil's label/value layout shifts between macOS releases. If a
      # scrape lands on the wrong field, `$((rssi - noise))` below raises a
      # syntax error and the `[ "$rssi" -ge -55 ]` ladder spews "integer
      # expression expected". Blank anything non-numeric so those blocks
      # skip cleanly and the section reports "unknown" instead.
      is_numeric "$rssi"  || rssi=""
      is_numeric "$noise" || noise=""
      WIFI_RSSI="${rssi:-}"
      WIFI_NOISE="${noise:-}"
      [ -n "$rssi" ]  && info "RSSI: ${rssi} dBm"
      [ -n "$noise" ] && info "Noise: ${noise} dBm"
      if [ -n "$rssi" ] && [ -n "$noise" ]; then
        WIFI_SNR=$((rssi - noise))
        info "SNR: ${WIFI_SNR} dB"
      fi
      [ -n "$WIFI_CHAN" ] && info "Channel: $WIFI_CHAN"
      [ -n "$WIFI_PHY" ]  && info "PHY: $WIFI_PHY"
      [ -n "$WIFI_TX" ]   && info "Tx Rate: $WIFI_TX"

      if [ -n "$rssi" ]; then
        if   [ "$rssi" -ge -55 ]; then ok   "Signal: excellent (RSSI ${rssi})"
        elif [ "$rssi" -ge -65 ]; then ok   "Signal: good (RSSI ${rssi})"
        elif [ "$rssi" -ge -72 ]; then warn "Signal: fair (RSSI ${rssi}) — may see latency spikes"
        elif [ "$rssi" -ge -80 ]; then warn "Signal: weak (RSSI ${rssi}) — expect retransmissions"
        else                            bad  "Signal: very weak (RSSI ${rssi}) — likely the problem"
        fi
      fi
      if [ -n "$WIFI_SNR" ]; then
        if   [ "$WIFI_SNR" -ge 40 ]; then :
        elif [ "$WIFI_SNR" -ge 25 ]; then info "SNR fine"
        elif [ "$WIFI_SNR" -ge 15 ]; then warn "SNR low (${WIFI_SNR} dB) — interference likely"
        else                              bad  "SNR very low (${WIFI_SNR} dB) — heavy interference"
        fi
      fi
    fi

    # macOS Tahoe redacts SSID/BSSID by default for unprivileged callers.
    # Even under sudo, wdutil only returns the real SSID/BSSID if the calling
    # terminal has been granted Location Services. Surface that as a hint
    # the one time it actually matters.
    if [ "$WIFI_SSID" = "<redacted>" ] || [ -z "$WIFI_SSID" ]; then
      info "SSID/BSSID hidden by macOS — grant Terminal 'Location Services' permission"
      info "(System Settings → Privacy & Security → Location Services → Terminal)."
    fi
  else
    info "Not on WiFi (interface $INTERFACE looks wired)."
  fi
}
