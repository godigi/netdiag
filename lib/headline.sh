# shellcheck shell=bash
# lib/headline.sh — "Report" card printed before the diagnoses. One line
# per category, status icon + label column + value. Replaces the prior
# dense one-line summary so a non-technical reader can scan health at a
# glance.
#
# Reads:  most module globals. Stays read-only.
# Entry:  headline_run

# Hdr() flips DIAGNOSIS_REACHED on "Report" so all the say() calls below
# print even in default mode (where section bodies are suppressed).

headline_run() {
  # --quiet wants only the diagnoses themselves — skip the Report card.
  [ "$QUIET" -eq 0 ] || return 0

  hdr "Report"

  # Rows are buffered into severity tiers and emitted in priority order
  # (bad → warn → ok → neutral) so the user sees the things that need
  # attention first. Within each tier we keep insertion order so the
  # logical grouping in the code (network → router → internet → …) holds.
  local _bad_rows=() _warn_rows=() _ok_rows=() _neutral_rows=()

  # In a focused run (--mtu-only / --wifi-only) most checks never execute,
  # so their rows would report module defaults — "IPv6 not available",
  # "Hosts file clean" — that were never actually measured. Emit only the
  # rows belonging to the focused section.
  _focus_allows() {
    [ -n "$FOCUS" ] || return 0
    case "$FOCUS:$1" in
      mtu:Network|mtu:Internet|mtu:"Packet size") return 0 ;;
      wifi:Network|wifi:"WiFi channel")           return 0 ;;
      *)                                          return 1 ;;
    esac
  }

  # Each row: icon · dim label (padded) · value. The icon's colour comes
  # from the severity arg. Dim labels keep the value column the visual
  # anchor — your eye lands on the data, not the column header.
  _row() {
    local sev="$1" label="$2" value="$3"
    _focus_allows "$label" || return 0
    local icon
    case "$sev" in
      ok)   icon="${C_GRN}✓${C_RESET}" ;;
      warn) icon="${C_YEL}⚠${C_RESET}" ;;
      bad)  icon="${C_RED}✗${C_RESET}" ;;
      *)    icon="${C_DIM}·${C_RESET}" ;;
    esac
    local line
    line="$(printf '  %s  %s%-18s%s  %s' \
      "$icon" "${C_DIM}" "$label" "${C_RESET}" "$value")"
    case "$sev" in
      bad)  _bad_rows+=("$line") ;;
      warn) _warn_rows+=("$line") ;;
      ok)   _ok_rows+=("$line") ;;
      *)    _neutral_rows+=("$line") ;;
    esac
  }

  # ── Network connection (interface + WiFi info) ─────────────────────────
  if [ -n "$INTERFACE" ]; then
    local netline="$INTERFACE"
    if [ "$IS_WIFI" -eq 1 ]; then
      netline="$netline · WiFi"
      [ -n "$WIFI_SCAN_CURRENT_BAND" ]    && netline="$netline ${WIFI_SCAN_CURRENT_BAND}"
      [ -n "$WIFI_SCAN_CURRENT_CHANNEL" ] && netline="$netline ch${WIFI_SCAN_CURRENT_CHANNEL}"
      if [ -n "$WIFI_RSSI" ]; then
        local quality="excellent"
        [ "$WIFI_RSSI" -lt -55 ] && quality="good"
        [ "$WIFI_RSSI" -lt -65 ] && quality="fair"
        [ "$WIFI_RSSI" -lt -72 ] && quality="weak"
        [ "$WIFI_RSSI" -lt -80 ] && quality="very weak"
        netline="$netline · ${WIFI_RSSI} dBm ($quality)"
      fi
    else
      netline="$netline · wired"
    fi
    _row ok "Network" "$netline"
  else
    _row bad "Network" "no default route"
  fi

  # ── VPN (always shown so the user can confirm one way or the other) ──
  if [ "$VPN_ACTIVE" -eq 1 ]; then
    # When a VPN is up, the "Internet" row's location reflects the VPN
    # exit (because we look it up via curl, which goes through the VPN).
    _row "" "VPN" "active · ${VPN_NAME:-?} · exit shown on Internet row"
  else
    _row "" "VPN" "not active"
  fi

  # ── Router (gateway) — loss / latency / jitter ────────────────────────
  if [ -n "$GATEWAY" ] && [ -n "$GW_LOSS" ] && [ -n "$GW_LATENCY" ]; then
    local sev=ok
    [ "${GW_LOSS%.*}" -ge 1 ]  && sev=warn
    [ "${GW_LOSS%.*}" -ge 20 ] && sev=bad
    local rline
    rline="$GATEWAY · ${GW_LOSS%.*}% loss · $(printf '%.1f' "$GW_LATENCY" 2>/dev/null || printf '%s' "$GW_LATENCY") ms"
    [ -n "$GW_JITTER" ] && rline="$rline · ±$(printf '%.1f' "$GW_JITTER" 2>/dev/null || printf '%s' "$GW_JITTER") ms jitter"
    _row "$sev" "Router" "$rline"
  fi

  # ── Internet (public reach) ───────────────────────────────────────────
  if [ "$PUBLIC_OK" -eq 1 ]; then
    local publine="${PUB_ISP:-?}"
    [ -n "$PUB_CITY" ] && publine="$publine (${PUB_CITY}${PUB_CC:+, $PUB_CC})"
    _row ok "Internet" "$publine"
  else
    _row bad "Internet" "unreachable"
  fi

  # ── Internet latency / jitter (always-on probe to 1.1.1.1) ────────────
  if [ -n "$INET_RTT_AVG" ]; then
    local sev=ok
    [ -n "$INET_LOSS" ] && [ "${INET_LOSS%.*}" -ge 1 ] && sev=warn
    [ -n "$INET_LOSS" ] && [ "${INET_LOSS%.*}" -ge 20 ] && sev=bad
    # High jitter (> 30 ms stddev) marks an unstable connection even at low loss.
    if [ -n "$INET_RTT_JITTER" ] && awk -v j="$INET_RTT_JITTER" 'BEGIN{exit !(j > 30)}'; then
      [ "$sev" = ok ] && sev=warn
    fi
    local iline
    iline="1.1.1.1 · $(printf '%.0f' "$INET_RTT_AVG" 2>/dev/null || printf '%s' "$INET_RTT_AVG") ms"
    [ -n "$INET_RTT_JITTER" ] && iline="$iline · ±$(printf '%.1f' "$INET_RTT_JITTER" 2>/dev/null || printf '%s' "$INET_RTT_JITTER") ms jitter"
    [ -n "$INET_LOSS" ] && [ "${INET_LOSS%.*}" -gt 0 ] && iline="$iline · ${INET_LOSS}% loss"
    _row "$sev" "Latency" "$iline"
  elif [ "$QUICK" -eq 1 ]; then
    _row "" "Latency" "skipped (--quick)"
  fi

  # ── DNS ──────────────────────────────────────────────────────────────
  # DNS_OK defaults to 0, so gate on DNS_LINES — proof the check actually
  # ran. Otherwise a run that skipped DNS (a focused --mtu-only pass)
  # reports lookups as failing when nothing was ever looked up.
  if [ -n "$DNS_LINES" ]; then
    if [ "$DNS_OK" -eq 1 ]; then
      _row ok "DNS" "working"
    else
      _row warn "DNS" "some lookups failing"
    fi
  fi

  # ── IPv6 ─────────────────────────────────────────────────────────────
  if [ "$IPV6_AVAILABLE" -eq 1 ]; then
    local v6_ok=1
    [ "$IPV6_AAAA_OK" -eq 0 ] && v6_ok=0
    [ "$IPV6_TCP_OK" -eq 0 ]  && v6_ok=0
    [ -n "$IPV6_PING_LOSS" ] && [ "${IPV6_PING_LOSS%.*}" -ge 20 ] && v6_ok=0
    if [ "$v6_ok" -eq 1 ]; then
      _row ok "IPv6" "working"
    else
      _row warn "IPv6" "available but broken — see below"
    fi
  else
    _row "" "IPv6" "not available (IPv4-only network)"
  fi

  # ── Speed test (only if --speed was passed and got a result) ──────────
  if [ -n "$SPEEDTEST_DOWN_MBPS" ]; then
    _row ok "Speed" "${SPEEDTEST_DOWN_MBPS} Mbps down · ${SPEEDTEST_UP_MBPS} Mbps up · ${SPEEDTEST_LATENCY_MS} ms"
  elif [ "$SPEED" -eq 1 ]; then
    _row warn "Speed" "test ran but returned no result"
  elif [ "$QUICK" -eq 1 ]; then
    _row "" "Speed" "skipped (--quick)"
  else
    _row "" "Speed" "not tested (run with --speed)"
  fi

  # ── Bufferbloat ──────────────────────────────────────────────────────
  if [ -n "$BUFFERBLOAT_GW_GRADE" ] && [ -n "$BUFFERBLOAT_INET_GRADE" ]; then
    local bb_sev=ok bb_descr=""
    case "${BUFFERBLOAT_GW_GRADE}${BUFFERBLOAT_INET_GRADE}" in
      AA|AB|BA|BB) bb_sev=ok;   bb_descr="clean under load" ;;
      *C*)         bb_sev=warn; bb_descr="noticeable lag under load" ;;
      *D*|*F*)     bb_sev=bad;  bb_descr="severe lag under load" ;;
    esac
    _row "$bb_sev" "Bufferbloat" "grade ${BUFFERBLOAT_GW_GRADE}/${BUFFERBLOAT_INET_GRADE} · $bb_descr"
  elif [ "$NO_BUFFERBLOAT" -eq 1 ] || [ "$QUICK" -eq 1 ]; then
    _row "" "Bufferbloat" "skipped (--quick / --no-bufferbloat)"
  fi

  # ── MTU (packet size) ────────────────────────────────────────────────
  if [ -n "$MTU_EFFECTIVE" ]; then
    local mtu_sev=ok mtu_note="standard"
    if [ "$MTU_EFFECTIVE" -lt 1400 ]; then
      mtu_sev=bad; mtu_note="severely clamped · many sites broken"
    elif [ "$MTU_EFFECTIVE" -lt 1500 ]; then
      mtu_sev=warn; mtu_note="below standard · some sites may hang"
    fi
    _row "$mtu_sev" "Packet size" "$MTU_EFFECTIVE bytes · $mtu_note"
  elif [ "$QUICK" -eq 1 ]; then
    _row "" "Packet size" "skipped (--quick)"
  fi

  # ── NAT topology ─────────────────────────────────────────────────────
  # WAN_DOUBLE_NAT counts home-side routers only; ISP-side 10/8 transit is
  # normal carrier routing and gets a neutral row, not a warning.
  if [ "$WAN_DOUBLE_NAT" -eq 1 ]; then
    _row warn "NAT topology" "double-NAT · ${WAN_NAT_HOME_COUNT} routers chained"
  elif [ "$WAN_NAT_ISP_COUNT" -gt 1 ]; then
    _row "" "NAT topology" "ISP transit via private addresses (normal)"
  fi

  # ── UPnP / router config ─────────────────────────────────────────────
  case "$WAN_UPNP_STATE" in
    enabled)  _row warn "Router config" "UPnP / port-forwarding enabled" ;;
    disabled) _row ok "Router config" "UPnP disabled (safer default)" ;;
  esac

  # ── WiFi congestion (only when crowded) ──────────────────────────────
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt 3 ]; then
    _row warn "WiFi channel" "crowded · ${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} neighbouring networks"
  fi

  # ── Clock drift (only when off by > 1 s) ─────────────────────────────
  if [ -n "$NTP_DRIFT_S" ]; then
    local drift_abs
    drift_abs="$(awk -v d="$NTP_DRIFT_S" 'BEGIN{print (d<0)?-d:d}')"
    if awk -v d="$drift_abs" 'BEGIN{exit !(d > 30)}'; then
      _row bad "Clock" "off by ${NTP_DRIFT_S} s"
    elif awk -v d="$drift_abs" 'BEGIN{exit !(d > 1)}'; then
      _row warn "Clock" "off by ${NTP_DRIFT_S} s"
    fi
  fi

  # ── ARP issues (only when present) ───────────────────────────────────
  if [ "$ARP_GW_INCOMPLETE" -eq 1 ]; then
    _row bad "Local network" "can't reach router at hardware layer"
  elif [ -n "${ARP_DUPLICATE_IPS//[[:space:]]/}" ]; then
    _row bad "Local network" "duplicate IP(s) on the LAN"
  fi

  # ── /etc/hosts ──────────────────────────────────────────────────────
  if [ -n "$HOSTS_SUSPICIOUS_LINES" ]; then
    local n_susp
    n_susp="$(printf '%s\n' "$HOSTS_SUSPICIOUS_LINES" | grep -c .)"
    _row warn "Hosts file" "${n_susp} entr$([ "$n_susp" -eq 1 ] && echo y || echo ies) redirect well-known services"
  elif [ "$HOSTS_CUSTOM_COUNT" -gt 0 ]; then
    _row "" "Hosts file" "$HOSTS_CUSTOM_COUNT custom entr$([ "$HOSTS_CUSTOM_COUNT" -eq 1 ] && echo y || echo ies)"
  else
    _row ok "Hosts file" "clean (only macOS defaults)"
  fi

  # ── Emit in priority order ──────────────────────────────────────────
  # Bad first (need-attention), then warnings, then healthy items, then
  # neutral/informational. A blank line separates the warn tier from
  # the healthy tier so the eye anchors on what needs action.
  local line
  for line in "${_bad_rows[@]}";  do say "$line"; done
  for line in "${_warn_rows[@]}"; do say "$line"; done
  if [ "${#_bad_rows[@]}" -gt 0 ] || [ "${#_warn_rows[@]}" -gt 0 ]; then
    [ "${#_ok_rows[@]}" -gt 0 ] || [ "${#_neutral_rows[@]}" -gt 0 ] && say ""
  fi
  for line in "${_ok_rows[@]}";      do say "$line"; done
  for line in "${_neutral_rows[@]}"; do say "$line"; done
}
