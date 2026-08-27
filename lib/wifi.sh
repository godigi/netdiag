# shellcheck shell=bash
# lib/wifi.sh — WiFi info: SSID/BSSID/security via ipconfig getsummary,
# plus RSSI/noise/channel/PHY/tx-rate via wdutil (which needs cached sudo).
#
# Reads:  INTERFACE
# Writes: IS_WIFI, WIFI_SSID, WIFI_BSSID, WIFI_SEC, WIFI_RSSI, WIFI_NOISE,
#         WIFI_SNR, WIFI_CHAN, WIFI_PHY, WIFI_TX
# Entry:  wifi_run

# Writes IS_WIFI, WIFI_* — read by diagnosis.sh / output.sh / emit_json.py.
# The upstream scrapes are shared with the live monitor; parse them once.
# shellcheck source=lib/wifi_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/wifi_common.sh"
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
    hw_port="$(wifi_hw_port_for_device "$INTERFACE")"
    if wifi_port_is_wireless "$hw_port"; then
      IS_WIFI=1
      # Pull SSID from ipconfig getsummary (works without sudo on modern macOS).
      local summary ssid bssid sec
      summary="$(ipconfig getsummary "$INTERFACE" 2>/dev/null)"
      {
        IFS=$'\t' read -r ssid bssid sec
      } <<<"$(wifi_parse_ipconfig_summary "$summary")"
      WIFI_SSID="$ssid"
      WIFI_BSSID="$bssid"
      WIFI_SEC="$sec"
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
      wdutil_out="$(with_timeout 5 sudo -n wdutil info 2>/dev/null || true)"
    fi

    # Whether the privileged scrape happened at all. Without it RSSI,
    # noise, SNR, channel, PHY and tx rate are *unavailable*, which is a
    # different fact from "measured and found quiet" — and until this
    # flag existed the record could not tell the two apart. That is
    # exactly why the three WiFi-flapping episodes in the project's own
    # history (112, 241 and 173 disassociations in an hour) are
    # undiagnosable after the fact: every radio field in those stored
    # spikes is null, and nothing says whether that meant silence or an
    # unprivileged run.
    WIFI_PRIVILEGED=0
    [ -n "$wdutil_out" ] && WIFI_PRIVILEGED=1

    if [ -n "$wdutil_out" ]; then
      local rssi noise chan tx phy w_ssid w_bssid
      # One parse for the whole scrape — see wifi_common.sh.
      {
        IFS=$'\t' read -r rssi noise chan tx phy w_ssid w_bssid
      } <<<"$(wifi_parse_wdutil "$wdutil_out")"
      # wdutil's SSID/BSSID is unredacted *if* the calling process has
      # Wi-Fi-access entitlement (Terminal with Location Services granted).
      # Override the ipconfig values when wdutil gave us something real.
      if [ -n "$w_ssid" ] && [ "$w_ssid" != "<redacted>" ]; then
        WIFI_SSID="$w_ssid"
      fi
      if [ -n "$w_bssid" ] && [ "$w_bssid" != "<redacted>" ]; then
        WIFI_BSSID="$w_bssid"
      fi
      # wdutil's label/value layout shifts between macOS releases. If a
      # scrape lands on the wrong field, `$((rssi - noise))` below raises a
      # syntax error and the RSSI/SNR comparisons spew "integer expression
      # expected". Blank anything non-numeric so those blocks
      # skip cleanly and the section reports "unknown" instead.
      is_numeric "$rssi"  || rssi=""
      is_numeric "$noise" || noise=""
      WIFI_RSSI="${rssi:-}"
      WIFI_NOISE="${noise:-}"
      WIFI_CHAN="$chan"
      WIFI_TX="$tx"
      WIFI_PHY="$phy"
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
        if   [ "$rssi" -ge "$THRESH_WIFI_RSSI_EXCELLENT_DBM" ]; then ok   "Signal: excellent (RSSI ${rssi})"
        elif [ "$rssi" -ge "$THRESH_WIFI_RSSI_G1_DBM" ]; then ok   "Signal: good (RSSI ${rssi})"
        elif [ "$rssi" -ge "$THRESH_WIFI_RSSI_WEAK_DBM" ]; then warn "Signal: fair (RSSI ${rssi}) — may see latency spikes"
        else                            warn "Signal: weak (RSSI ${rssi}) — expect retransmissions"
        fi
      fi
      if [ -n "$WIFI_SNR" ]; then
        if [ "$WIFI_SNR" -ge "$THRESH_WIFI_SNR_LOW_DB" ]; then
          info "SNR fine"
        else
          warn "SNR low (${WIFI_SNR} dB) — interference likely"
        fi
      fi
    fi

    # macOS Tahoe redacts SSID/BSSID by default for unprivileged callers.
    # Even under sudo, wdutil only returns the real SSID/BSSID if the calling
    # terminal has been granted Location Services. Surface that as a hint
    # the one time it actually matters.
    if [ "$WIFI_SSID" = "<redacted>" ] || [ -z "$WIFI_SSID" ]; then
      # Recorded as well as printed. These two `info` lines are
      # suppressed in a default run, and the *stored* consequence is the
      # one that bites: every run on this network is filed under
      # "WiFi (SSID hidden by macOS)", so runs on genuinely different
      # networks become indistinguishable in history. WI-1 is what makes
      # that visible to the user; this flag is what tells it to fire.
      WIFI_NAME_HIDDEN=1
      info "SSID/BSSID hidden by macOS — grant Terminal 'Location Services' permission"
      info "(System Settings → Privacy & Security → Location Services → Terminal)."
    fi
  else
    info "Not on WiFi (interface $INTERFACE looks wired)."
  fi
}
