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

# The Bufferbloat row's severity and wording, from the two Waveform grades
# ($1 = gateway leg, $2 = ISP leg). Echoes "sev|description".
#
# Pure, and a named function rather than an inline `case`, for the same
# reason StageResolver is a pure function on the GUI side: this is a mapping
# that must agree with a *second* engine, and the only way to hold two
# engines to one table is to be able to run the table.
#
# The engine it must agree with is B1/B2 in lib/diagnosis.sh, which grade
# each leg separately and let the worst one own the verdict: C is warn, D
# and F are critical. So the worst grade wins here too, which means D and F
# are matched BEFORE C.
#
# That order is the whole bug this function was extracted for. `case` takes
# the first arm that matches, and with `*C*` written first the pair "C/F"
# matched it and stopped — a grade F link was described as "noticeable lag
# under load" in a yellow row, directly above B2's own red diagnosis calling
# the same link critical and "enough to ruin voice/video calls and
# multiplayer games". Two severities for one fact, one screen apart. Every
# C-plus-D/F pair was affected: CD, DC, CF and FC.
bufferbloat_card_verdict() {
  case "${1}${2}" in
    AA|AB|BA|BB) printf 'ok|clean under load\n' ;;
    *D*|*F*)     printf 'bad|severe lag under load\n' ;;
    *C*)         printf 'warn|noticeable lag under load\n' ;;
    # No grade pair reaches here today — grade_bufferbloat only ever
    # returns A-F — but an unrecognised pair must not silently inherit
    # "ok" and paint a green row over a link nobody graded.
    *)           printf '|not graded\n' ;;
  esac
}

headline_run() {
  # --quiet wants only the diagnoses themselves — skip the Report card.
  [ "$QUIET" -eq 0 ] || return 0

  hdr "Report"

  # Rows are buffered into severity tiers and emitted in priority order
  # (bad → warn → ok → neutral) so the user sees the things that need
  # attention first. Within each tier we keep insertion order so the
  # logical grouping in the code (network → router → internet → …) holds.
  local _bad_rows=() _warn_rows=() _ok_rows=() _neutral_rows=()

  # In a focused run (--mtu-only / --wifi-only / --speed-only) most checks
  # never execute, so their rows would report module defaults — "IPv6 not
  # available", "Hosts file clean" — that were never actually measured.
  # Emit only the rows belonging to the focused section.
  _focus_allows() {
    [ -n "$FOCUS" ] || return 0
    case "$FOCUS:$1" in
      mtu:Network|mtu:Internet|mtu:"Packet size")        return 0 ;;
      wifi:Network|wifi:"WiFi channel")                  return 0 ;;
      dns:Network|dns:DNS)                                return 0 ;;
      bufferbloat:Network|bufferbloat:Router|bufferbloat:Internet|bufferbloat:Bufferbloat) return 0 ;;
      ping:Network|ping:Router|ping:Internet|ping:Latency|ping:"Packet loss") return 0 ;;
      # Router earns its place in a speed-only run: gateway_run is what
      # refreshes the ARP entry the record's network identity comes from,
      # so it really was measured and hiding it would be the lie.
      speed:Network|speed:Router|speed:Internet|speed:Speed) return 0 ;;
      *)                                                 return 1 ;;
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
        local quality
        if [ "$WIFI_RSSI" -ge "$THRESH_WIFI_RSSI_EXCELLENT_DBM" ]; then
          quality="excellent"
        elif [ "$WIFI_RSSI" -ge "$THRESH_WIFI_RSSI_G1_DBM" ]; then
          quality="good"
        elif [ "$WIFI_RSSI" -ge "$THRESH_WIFI_RSSI_WEAK_DBM" ]; then
          quality="fair"
        else
          quality="weak"
        fi
        netline="$netline · ${WIFI_RSSI} dBm ($quality)"
      fi
    elif [ "${WIFI_CHECKED:-0}" -eq 1 ]; then
      netline="$netline · wired"
    fi
    # WIFI_CHECKED=0 means wifi_run never executed (--mtu-only), so the
    # medium is unknown — say nothing rather than guess "wired".
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
    # Thresholds are the shared LOSS_* constants, so a coloured row always
    # has a matching diagnosis below it. They used to diverge: the row went
    # yellow at 1% while the lowest gateway rule fired at 20%, so the band
    # between produced a warning-coloured card over the words "Nothing
    # obviously wrong" and an exit code of 0.
    local sev=ok
    loss_at_least "$GW_LOSS" "$LOSS_WARN_PCT" && sev=warn
    loss_at_least "$GW_LOSS" "$LOSS_CRIT_PCT" && sev=bad
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
    loss_at_least "$INET_LOSS" "$LOSS_WARN_PCT" && sev=warn
    # bad only when both targets agree, matching L1's critical guard —
    # one lossy anycast target is that operator rate-limiting ICMP.
    loss_at_least "$INET_LOSS"     "$LOSS_CRIT_PCT" \
      && loss_at_least "$INET_LOSS_ALT" "$LOSS_CRIT_PCT" && sev=bad
    # High jitter (> 30 ms stddev) marks an unstable connection even at low loss.
    if [ -n "$INET_RTT_JITTER" ] && awk -v j="$INET_RTT_JITTER" -v t="$THRESH_LATENCY_JITTER_WARN_MS" 'BEGIN{exit !(j > t)}'; then
      [ "$sev" = ok ] && sev=warn
    fi
    local iline
    iline="${INET_TARGET} · $(printf '%.0f' "$INET_RTT_AVG" 2>/dev/null || printf '%s' "$INET_RTT_AVG") ms"
    [ -n "$INET_RTT_JITTER" ] && iline="$iline · ±$(printf '%.1f' "$INET_RTT_JITTER" 2>/dev/null || printf '%s' "$INET_RTT_JITTER") ms jitter"
    [ -n "$INET_LOSS" ] && [ "${INET_LOSS%.*}" -gt 0 ] && iline="$iline · ${INET_LOSS}% loss"
    _row "$sev" "Latency" "$iline"
  elif [ "$QUICK" -eq 1 ]; then
    _row "" "Latency" "skipped (--quick)"
  fi

  # ── Packet loss (both public targets, side by side) ──────────────────
  # Its own row rather than a suffix on Latency: loss and latency are
  # different faults with different fixes, and loss is the one users
  # experience as "the internet is down".
  if loss_measured "$INET_LOSS" || loss_measured "$INET_LOSS_ALT"; then
    local lsev=ok lline
    loss_at_least "$INET_LOSS" "$LOSS_WARN_PCT" && lsev=warn
    loss_at_least "$INET_LOSS_ALT" "$LOSS_WARN_PCT" && lsev=warn
    loss_at_least "$INET_LOSS"     "$LOSS_CRIT_PCT" \
      && loss_at_least "$INET_LOSS_ALT" "$LOSS_CRIT_PCT" && lsev=bad
    lline="${INET_LOSS:-?}% to ${INET_TARGET} · ${INET_LOSS_ALT:-?}% to ${INET_TARGET_ALT}"
    [ "$lsev" = ok ] && lline="$lline · clean"
    _row "$lsev" "Packet loss" "$lline"
  elif [ "$QUICK" -eq 1 ]; then
    _row "" "Packet loss" "skipped (--quick)"
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
    [ -n "$IPV6_PING_LOSS" ] && [ "${IPV6_PING_LOSS%.*}" -ge "$THRESH_IPV6_LOSS_PCT" ] && v6_ok=0
    if [ "$v6_ok" -eq 1 ]; then
      _row ok "IPv6" "working"
    else
      _row warn "IPv6" "available but broken — see below"
    fi
  else
    _row "" "IPv6" "not available (IPv4-only network)"
  fi

  # ── Speed test (only if --speed was passed and got a result) ──────────
  # Ordering matters: SPEED defaults to 1 from v0.6.0, so the old "elif
  # SPEED -eq 1 → test ran but returned no result" branch would have
  # claimed a failed test on every machine that simply skipped it. Each
  # reason for having no number is now checked before that fallback.
  if [ -n "$SPEEDTEST_DOWN_MBPS" ]; then
    _row ok "Speed" "${SPEEDTEST_DOWN_MBPS} Mbps down · ${SPEEDTEST_UP_MBPS} Mbps up · ${SPEEDTEST_LATENCY_MS} ms"
  elif speedtest_will_run; then
    # The card is printed before the test now, so there is no result to
    # show yet. Promise it rather than claiming it wasn't measured.
    _row "" "Speed" "measuring now — result prints below (~1 min)"
  elif [ "$NO_SPEED" -eq 1 ]; then
    _row "" "Speed" "skipped (--no-speed)"
  elif [ "$QUICK" -eq 1 ] && [ "${SPEED_EXPLICIT:-0}" -eq 0 ]; then
    _row "" "Speed" "skipped (--quick)"
  elif [ "$PUBLIC_OK" -eq 0 ]; then
    _row "" "Speed" "not measured (no internet to test against)"
  elif [ "$(speedtest_flavor)" = "none:" ]; then
    _row "" "Speed" "not measured · brew install speedtest"
  else
    _row warn "Speed" "test ran but returned no result"
  fi

  # ── Bufferbloat ──────────────────────────────────────────────────────
  if [ -n "$BUFFERBLOAT_GW_GRADE" ] && [ -n "$BUFFERBLOAT_INET_GRADE" ]; then
    local bb_verdict bb_sev bb_descr
    bb_verdict="$(bufferbloat_card_verdict "$BUFFERBLOAT_GW_GRADE" "$BUFFERBLOAT_INET_GRADE")"
    bb_sev="${bb_verdict%%|*}"
    bb_descr="${bb_verdict#*|}"
    _row "$bb_sev" "Bufferbloat" "grade ${BUFFERBLOAT_GW_GRADE}/${BUFFERBLOAT_INET_GRADE} · $bb_descr"
  elif [ "$NO_BUFFERBLOAT" -eq 1 ] || [ "$QUICK" -eq 1 ]; then
    _row "" "Bufferbloat" "skipped (--quick / --no-bufferbloat)"
  fi

  # ── MTU (packet size) ────────────────────────────────────────────────
  if [ -n "$MTU_EFFECTIVE" ]; then
    local mtu_sev=ok mtu_note="standard"
    if [ "$MTU_EFFECTIVE" -lt "$THRESH_MTU_STANDARD" ]; then
      mtu_sev=bad; mtu_note="severely clamped · many sites broken"
    elif [ "$MTU_EFFECTIVE" -lt "$THRESH_MTU_ETHERNET" ]; then
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
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt "$THRESH_WIFI_CHANNEL_NEIGHBOURS" ]; then
    _row warn "WiFi channel" "crowded · ${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} neighbouring networks"
  fi

  # ── Clock drift (only when off by > 1 s) ─────────────────────────────
  if [ -n "$NTP_DRIFT_S" ]; then
    local drift_abs
    drift_abs="$(awk -v d="$NTP_DRIFT_S" 'BEGIN{print (d<0)?-d:d}')"
    if awk -v d="$drift_abs" -v t="$THRESH_NTP_DRIFT_CRIT_S" 'BEGIN{exit !(d > t)}'; then
      _row bad "Clock" "off by ${NTP_DRIFT_S} s"
    elif awk -v d="$drift_abs" -v t="$THRESH_NTP_DRIFT_WARN_S" 'BEGIN{exit !(d > t)}'; then
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

  # ── Local traffic (only when there was some) ────────────────────────
  # No row on an idle Mac: "0.03 Mb/s" in every report is noise, and the
  # row exists to answer one question — was something of yours competing
  # with the measurements above. Severity mirrors TR-1's, which is why
  # the same threshold decides both.
  if traffic_at_least "$THRESH_TRAFFIC_BUSY_MBPS"; then
    local _tr_label
    _tr_label="$(traffic_busier_direction)"
    if [ -n "${TRAFFIC_TOP_NAME:-}" ]; then
      _tr_label="$_tr_label · $TRAFFIC_TOP_NAME"
    fi
    _row warn "Local traffic" "$_tr_label"
  fi

  # ── Background watcher (only when one is installed) ─────────────────
  # No row at all for the overwhelming majority of runs, where no watcher
  # exists: a "not installed" line in every report is an advertisement,
  # not a finding. The state comes from watchdog_run, the same value ND-1
  # reads, so this row and that diagnosis cannot contradict each other.
  #
  # Every fault state is `warn`, never `bad`, and that is a deliberate
  # ceiling rather than an accident of wording. `bad` rows sort to the
  # very top of this card, above the network itself, and nothing about
  # the network is wrong when this fires — a red mark over "can't run
  # from this folder" as the first thing in a report about a healthy
  # connection is the wrong altitude. It matches ND-1's own severity,
  # so the row and the diagnosis rank the same fact the same way.
  case "${WATCHER_STATE:-absent}" in
    blocked) _row warn "Background watcher" "can't run from this folder" ;;
    failing) _row warn "Background watcher" "last run exited ${WATCHER_LAST_EXIT}" ;;
    never)   _row warn "Background watcher" "has never run" ;;
    stale)   _row warn "Background watcher" "last ran $(watchdog_fmt_age "$WATCHER_HEARTBEAT_AGE_S") ago" ;;
    pending) _row ""   "Background watcher" "installed, hasn't run yet" ;;
    ok)      _row ok   "Background watcher" "last ran $(watchdog_fmt_age "$WATCHER_HEARTBEAT_AGE_S") ago" ;;
  esac

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
