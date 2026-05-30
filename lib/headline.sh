# shellcheck shell=bash
# lib/headline.sh — one-line "Summary" panel printed just before Diagnosis.
# Reads the headline metrics from globals populated by every other module
# and emits them in a single greppable line. Bad/warn parts get coloured
# so users can spot them at a glance.
#
# Reads:  GW_LOSS, GW_LATENCY, PUBLIC_OK, PUB_ISP, PUB_CC, DNS_OK, IS_WIFI,
#         WIFI_SCAN_CURRENT_CHANNEL, WIFI_RSSI, BUFFERBLOAT_GW_GRADE,
#         BUFFERBLOAT_INET_GRADE, MTU_EFFECTIVE, IPV6_AVAILABLE,
#         TCP_REACH_ANY_OK, WAN_DOUBLE_NAT, WAN_UPNP_STATE
# Entry:  headline_run

# Hdr() already flips DIAGNOSIS_REACHED on "Diagnosis" prefixes; the
# orchestrator calls headline_run right before diagnosis_run so QUIET-mode
# users still see the Summary too. The "Summary" prefix flips the flag.

headline_run() {
  hdr "Summary"

  local parts=()
  # Helper: append a coloured chunk to parts[]. Severity arg is optional —
  # neutral / informational chunks pass just the text.
  _hl_add() {
    local txt="$1" sev="${2:-}"
    case "$sev" in
      bad)  parts+=("${C_RED}${txt}${C_RESET}") ;;
      warn) parts+=("${C_YEL}${txt}${C_RESET}") ;;
      ok)   parts+=("${C_GRN}${txt}${C_RESET}") ;;
      *)    parts+=("$txt") ;;
    esac
  }

  # Gateway: loss% / latency-ms
  if [ -n "$GW_LOSS" ] && [ -n "$GW_LATENCY" ]; then
    local sev=ok
    [ "${GW_LOSS%.*}" -ge 1 ]  && sev=warn
    [ "${GW_LOSS%.*}" -ge 20 ] && sev=bad
    _hl_add "gw $(printf '%s' "${GW_LOSS%.*}")%/$(printf '%.1f' "$GW_LATENCY" 2>/dev/null || printf '%s' "$GW_LATENCY")ms" "$sev"
  fi

  # Public reach + ISP
  if [ "$PUBLIC_OK" -eq 1 ]; then
    _hl_add "pub ${PUB_ISP:-?}${PUB_CC:+ ($PUB_CC)}" ok
  else
    _hl_add "pub unreachable" bad
  fi

  # DNS
  if [ "$DNS_OK" -eq 1 ]; then _hl_add "DNS ok" ok; else _hl_add "DNS partial" warn; fi

  # WiFi (channel / RSSI) — only when on WiFi
  if [ "$IS_WIFI" -eq 1 ]; then
    local wp="WiFi" sev=ok
    [ -n "$WIFI_SCAN_CURRENT_CHANNEL" ] && wp="${wp} ch${WIFI_SCAN_CURRENT_CHANNEL}"
    if [ -n "$WIFI_RSSI" ]; then
      wp="${wp}/${WIFI_RSSI}dBm"
      [ "$WIFI_RSSI" -lt -72 ] && sev=warn
      [ "$WIFI_RSSI" -lt -80 ] && sev=bad
    fi
    _hl_add "$wp" "$sev"
  fi

  # Bufferbloat — only when both grades exist
  if [ -n "$BUFFERBLOAT_GW_GRADE" ] && [ -n "$BUFFERBLOAT_INET_GRADE" ]; then
    local bb="BB ${BUFFERBLOAT_GW_GRADE}/${BUFFERBLOAT_INET_GRADE}" sev=ok
    case "${BUFFERBLOAT_GW_GRADE}${BUFFERBLOAT_INET_GRADE}" in
      *D*|*F*) sev=bad ;;
      *C*)     sev=warn ;;
    esac
    _hl_add "$bb" "$sev"
  fi

  # PMTU
  if [ -n "$MTU_EFFECTIVE" ]; then
    local sev=ok
    [ "$MTU_EFFECTIVE" -lt 1500 ] && sev=warn
    [ "$MTU_EFFECTIVE" -lt 1400 ] && sev=bad
    _hl_add "PMTU $MTU_EFFECTIVE" "$sev"
  fi

  # IPv6
  if [ "$IPV6_AVAILABLE" -eq 1 ]; then _hl_add "v6 ok" ok; else _hl_add "v4-only" ; fi

  # NAT topology
  if [ "$WAN_DOUBLE_NAT" -eq 1 ]; then _hl_add "NAT double" warn; fi

  # UPnP
  case "$WAN_UPNP_STATE" in
    enabled)  _hl_add "UPnP on"  warn ;;
    disabled) _hl_add "UPnP off" ok   ;;
  esac

  # Print the joined line via info() (colour stays, ANSI strips on the log
  # side). Use a single non-bulleted line — denser than the section bodies.
  local line=""
  local p
  for p in "${parts[@]}"; do
    if [ -z "$line" ]; then line="$p"; else line="$line ${C_DIM}·${C_RESET} $p"; fi
  done
  say "  $line"
}
