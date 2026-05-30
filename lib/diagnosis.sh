# shellcheck shell=bash
# lib/diagnosis.sh — apply the rule set, accumulate diagnoses, sort by
# severity, and print the Diagnosis section.
#
# Reads:  most module globals (WIFI_*, GW_*, PUBLIC_OK, DNS_OK, MTU_*,
#         IPV6_*, TCP_REACH_*, NTP_*, ARP_*, DHCP_*, WAN_*)
# Writes: DIAG, DIAG_SEV, MOST_LIKELY_ROOT_CAUSE, DIAGNOSIS_LINES,
#         MAX_SEVERITY (indirectly via add_diag)
# Entry:  diagnosis_run
#
# Rule names match docs/DIAGNOSIS-RULES.md.

diagnosis_run() {
  hdr "Diagnosis"
  # W1, W2, G1/G2 — WiFi quality and gateway loss interplay.
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -75 ]; then
    add_diag warn "WiFi signal is weak (RSSI ${WIFI_RSSI}). Move closer to the AP, or switch bands/AP."
  fi
  if [ -n "$WIFI_SNR" ] && [ "$WIFI_SNR" -lt 20 ]; then
    add_diag warn "Low WiFi SNR (${WIFI_SNR} dB) suggests interference on this channel."
  fi
  if [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge 20 ]; then
    if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -70 ]; then
      add_diag critical "Gateway loss + weak WiFi → the WiFi link is your problem, not the router/ISP."
    else
      add_diag critical "Gateway loss with healthy WiFi → router itself is misbehaving (reboot it)."
    fi
  fi

  # P1/P2 — public unreachable.
  if [ "$PUBLIC_OK" -eq 0 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -eq 0 ]; then
    if [ "$DNS_OK" -eq 0 ]; then
      add_diag critical "LAN healthy but no public reach AND DNS failing → DNS or upstream ISP outage."
    else
      add_diag critical "LAN healthy, DNS working, but no public reach → ISP-side outage."
    fi
  fi

  # D1 — partial DNS, internet reachable.
  if [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then
    add_diag warn "Internet reachable but DNS partially broken → try changing resolver (1.1.1.1 / 8.8.8.8)."
  fi

  # B1/B2 — bufferbloat at gateway or ISP hop.
  case "${BUFFERBLOAT_GW_GRADE:-}" in
    C)   add_diag warn     "Bufferbloat at gateway (grade C, +${BUFFERBLOAT_GW_DELTA} ms under load) — router lacks SQM/fq_codel. Enable Smart Queue Management in the router UI." ;;
    D|F) add_diag critical "Bufferbloat at gateway (grade ${BUFFERBLOAT_GW_GRADE}, +${BUFFERBLOAT_GW_DELTA} ms under load) — router lacks SQM/fq_codel. VOIP/Zoom will glitch under load." ;;
  esac
  case "${BUFFERBLOAT_INET_GRADE:-}" in
    C)   add_diag warn     "Bufferbloat at ISP hop (grade C, +${BUFFERBLOAT_INET_DELTA} ms under load) — ISP's CPE/uplink is the bottleneck." ;;
    D|F) add_diag critical "Bufferbloat at ISP hop (grade ${BUFFERBLOAT_INET_GRADE}, +${BUFFERBLOAT_INET_DELTA} ms under load) — ISP CPE/uplink bottleneck. Call the ISP." ;;
  esac

  # M1 — path MTU below 1500.
  if [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt 1400 ]; then
    add_diag critical "Path MTU ${MTU_EFFECTIVE} (< 1400) — severe clamp. Most TLS sites will fail. Check for a misconfigured tunnel/VPN or PPPoE link."
  elif [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt 1500 ]; then
    add_diag warn "Path MTU ${MTU_EFFECTIVE} (< 1500) — TLS handshakes to some sites will hang while others work. Suspect PPPoE / VPN / tunnel that needs MSS clamping at the router."
  fi

  # MT1 — first lossy hop.
  if [ -n "$MTR_FIRST_LOSSY_HOP" ]; then
    add_diag warn "First lossy hop: $MTR_FIRST_LOSSY_HOP — blame this hop (and the router/ISP that owns it). Loss on subsequent hops is usually inherited from this one, not new."
  fi

  # V6-1 — IPv6 broken while IPv4 works.
  if [ "$IPV6_AVAILABLE" -eq 1 ]; then
    local v6_broken=0 aaaa_str tcp6_str
    [ -n "$IPV6_PING_LOSS" ] && [ "${IPV6_PING_LOSS%.*}" -ge 20 ] && v6_broken=1
    [ "$IPV6_AAAA_OK" -eq 0 ] && v6_broken=1
    [ "$IPV6_TCP_OK" -eq 0 ] && v6_broken=1
    if [ "$v6_broken" -eq 1 ] && [ "$PUBLIC_OK" -eq 1 ]; then
      aaaa_str=$([ "$IPV6_AAAA_OK" -eq 1 ] && echo OK || echo FAIL)
      tcp6_str=$([ "$IPV6_TCP_OK" -eq 1 ] && echo OK || echo FAIL)
      add_diag warn "IPv6 is broken (loss ${IPV6_PING_LOSS}%, AAAA ${aaaa_str}, TCP6 ${tcp6_str}) while IPv4 works — router/ISP v6 misconfig. Happy Eyeballs hides this and just makes some sites mysteriously slow."
    fi
  fi

  # TCP-1 — TCP works, ICMP is filtered.
  if [ "$TCP_REACH_ANY_OK" -eq 1 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge 50 ]; then
    add_diag info "TCP reach panel succeeded but gateway ping shows ${GW_LOSS}% loss — ICMP is being filtered somewhere on the path. Ignore the ping-based failures; the network itself is up."
  fi

  # WS-1 — congested WiFi channel.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt 3 ]; then
    add_diag warn "WiFi channel ${WIFI_SCAN_CURRENT_CHANNEL} has ${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} other APs visible — switch to a less crowded channel (5GHz 149/153/157/161 if your router supports it)."
  fi

  # WD-1 — WiFi flapping.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_DISCONNECT_COUNT" -gt 3 ]; then
    add_diag warn "WiFi link is flapping — $WIFI_DISCONNECT_COUNT disconnect/reassoc events in the past hour. Check for roaming between APs, marginal signal at the desk, or a router firmware bug."
  fi

  # NT-1 — system clock drift.
  if [ -n "$NTP_DRIFT_S" ] && awk -v d="$NTP_DRIFT_S" 'BEGIN{exit !((d<0?-d:d) > 30)}'; then
    add_diag critical "System clock drifted ${NTP_DRIFT_S}s — TLS handshakes are likely failing across the board. Re-enable network time (System Settings → General → Date & Time)."
  fi

  # DI-1 — duplicate IP / incomplete gateway ARP.
  if [ "$ARP_GW_INCOMPLETE" -eq 1 ]; then
    add_diag critical "Gateway ARP entry is (incomplete) — L2 to the router is broken. Cable/AP problem; ICMP and everything else above is meaningless until ARP resolves."
  fi
  if [ -n "${ARP_DUPLICATE_IPS//[[:space:]]/}" ]; then
    add_diag critical "Duplicate IP(s) detected in ARP: ${ARP_DUPLICATE_IPS}— another device on the LAN is using the same address. Static-IP collision or rogue DHCP."
  fi

  # DH-1 — DHCP lease expires soon.
  if [ -n "$DHCP_TIME_REMAINING_S" ] && [ "$DHCP_TIME_REMAINING_S" -gt 0 ] && [ "$DHCP_TIME_REMAINING_S" -lt 3600 ]; then
    add_diag warn "DHCP lease expires in $((DHCP_TIME_REMAINING_S / 60)) min — if the renewal fails (router rebooting / DHCP scope full), the link will drop without warning."
  fi

  # DH-2 — DHCP vs system DNS mismatch.
  if [ -n "$DHCP_DNS_SERVERS" ] && [ -n "$SYS_RES" ] && ! printf '%s' "$DHCP_DNS_SERVERS" | grep -qF "$SYS_RES"; then
    add_diag info "DHCP gave DNS as '$DHCP_DNS_SERVERS' but the system uses $SYS_RES — someone manually overrode it. Fine if intentional; surprising otherwise."
  fi

  # WAN-1 / WAN-1b / NAT-1 / UP-1 live in lib/wan.sh's diagnosis hook so
  # this file stays scoped to the older rules. The hook is a no-op stub
  # until the NAT/WAN section ships.
  if declare -f wan_diagnosis_run >/dev/null 2>&1; then
    wan_diagnosis_run
  fi

  MOST_LIKELY_ROOT_CAUSE=""
  if [ "${#DIAG[@]}" -eq 0 ]; then
    ok "Nothing obviously wrong from these checks."
    return 0
  fi
  # Sort by severity descending (critical → warn → info), preserving insertion
  # order within each severity. First line emitted becomes most_likely_root_cause.
  local s i
  for s in critical warn info; do
    for i in "${!DIAG[@]}"; do
      if [ "${DIAG_SEV[$i]}" = "$s" ]; then
        [ -z "$MOST_LIKELY_ROOT_CAUSE" ] && MOST_LIKELY_ROOT_CAUSE="${DIAG[$i]}"
        case "$s" in
          critical) bad  "${DIAG[$i]}" ;;
          warn)     warn "${DIAG[$i]}" ;;
          info)     info "${DIAG[$i]}" ;;
        esac
        DIAGNOSIS_LINES+="${s}|${DIAG[$i]}"$'\n'
      fi
    done
  done
}
