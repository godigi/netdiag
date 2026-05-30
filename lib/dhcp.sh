# shellcheck shell=bash
# lib/dhcp.sh — DHCP lease detail from ipconfig getsummary.
#
# Reads:  INTERFACE
# Writes: DHCP_SERVER, DHCP_LEASE_START, DHCP_LEASE_END,
#         DHCP_TIME_REMAINING_S, DHCP_DNS_SERVERS
# Entry:  dhcp_run

dhcp_run() {
  [ -n "$INTERFACE" ] || return 0

  hdr "DHCP lease"
  local dhcp_summary
  dhcp_summary="$(ipconfig getsummary "$INTERFACE" 2>/dev/null || true)"
  DHCP_SERVER="$(printf '%s' "$dhcp_summary"      | awk -F': ' '/server_identifier/{print $2; exit}')"
  DHCP_LEASE_START="$(printf '%s' "$dhcp_summary" | awk -F' : ' '/LeaseStartTime/{print $2; exit}')"
  DHCP_LEASE_END="$(printf '%s' "$dhcp_summary"   | awk -F' : ' '/LeaseExpirationTime/{print $2; exit}')"
  DHCP_DNS_SERVERS="$(printf '%s' "$dhcp_summary" | awk -F'[{}]' '/domain_name_server/{print $2; exit}')"

  [ -n "$DHCP_SERVER" ]       && info "DHCP server: $DHCP_SERVER"
  [ -n "$DHCP_LEASE_START" ]  && info "Lease started:  $DHCP_LEASE_START"
  [ -n "$DHCP_LEASE_END" ]    && info "Lease expires:  $DHCP_LEASE_END"
  if [ -n "$DHCP_LEASE_END" ]; then
    local lease_end_epoch now_epoch remaining_hrs
    lease_end_epoch="$(date -j -f '%m/%d/%Y %H:%M:%S' "$DHCP_LEASE_END" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if [ "$lease_end_epoch" -gt 0 ]; then
      DHCP_TIME_REMAINING_S=$((lease_end_epoch - now_epoch))
      if [ "$DHCP_TIME_REMAINING_S" -gt 0 ]; then
        remaining_hrs=$((DHCP_TIME_REMAINING_S / 3600))
        info "Time remaining: ~${remaining_hrs}h"
        if [ "$DHCP_TIME_REMAINING_S" -lt 3600 ]; then
          warn "Lease expires in $((DHCP_TIME_REMAINING_S / 60)) min — renewal failures could drop the link."
        fi
      fi
    fi
  fi
  [ -n "$DHCP_DNS_SERVERS" ] && info "DHCP-handed DNS: $DHCP_DNS_SERVERS"
}
