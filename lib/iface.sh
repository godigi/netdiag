# shellcheck shell=bash
# lib/iface.sh — local interface, IP, default gateway.
#
# The default route is ONE input here, not the definition of "connected".
# It used to be both: INTERFACE and GATEWAY were two awk passes over one
# `route -n get default`, and lib/wifi.sh, lib/dhcp.sh and lib/netid.sh all
# gate on INTERFACE — so a Mac sitting on a hotel network with a strong
# signal and a valid lease, but no route yet, reported no interface, no
# SSID, no lease and no network identity, and N1 told the user their WiFi
# was off. lib/linkstate.sh answers the association question separately;
# this file merges the two views.
#
# Reads:  THRESH_ROUTE_RECHECK_DELAY_S
# Writes: INTERFACE, LOCAL_IP, GATEWAY, GW_COUNT,
#         LINK_DEVICE, LINK_STATUS, LINK_IP, LINK_DHCP_ROUTER, LINK_UP
# Entry:  iface_run

# shellcheck source=lib/linkstate.sh
. "$(dirname "${BASH_SOURCE[0]}")/linkstate.sh"

# Writes LINK_* via linkstate_run — read in diagnosis.sh / netid.sh /
# emit_json.py, none of which shellcheck can follow from here.
# shellcheck disable=SC2034
iface_run() {
  hdr "Local network"

  local route_out
  route_out="$(route -n get default 2>/dev/null || true)"
  INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
  GATEWAY="$(printf '%s\n' "$route_out" | awk '/gateway:/{print $2; exit}')"

  # A missing default route is the single most alarming thing netdiag can
  # observe, and it is also the one most likely to be a transient: DHCP
  # renewals, WiFi roams and macOS re-evaluating a network service all
  # drop it for a moment. Read it once more before believing it. See
  # THRESH_ROUTE_RECHECK_DELAY_S for the evidence this is not theoretical.
  if [ -z "$GATEWAY" ]; then
    sleep "$THRESH_ROUTE_RECHECK_DELAY_S"
    route_out="$(route -n get default 2>/dev/null || true)"
    INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
    GATEWAY="$(printf '%s\n' "$route_out" | awk '/gateway:/{print $2; exit}')"
  fi

  # Association, address and DHCP router — none of which needs a route.
  # Seeded with the route's own interface when there is one, so the common
  # case costs a single ifconfig.
  linkstate_run "$INTERFACE"

  # With no route, the link's own device is the interface. Everything
  # downstream (WiFi, DHCP, netid) keys off INTERFACE, and on a portal
  # network those checks have real answers to give.
  [ -z "$INTERFACE" ] && INTERFACE="$LINK_DEVICE"

  LOCAL_IP=""
  if [ -n "$INTERFACE" ]; then
    LOCAL_IP="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null)"
  fi
  [ -z "$LOCAL_IP" ] && LOCAL_IP="$LINK_IP"

  if [ -n "$INTERFACE" ] && [ -n "$GATEWAY" ]; then
    ok "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   Gateway: $GATEWAY"
  elif [ "${LINK_UP:-0}" -eq 1 ]; then
    # Joined and addressed, but nothing to route through. Stated as the
    # fact it is; N1c in lib/diagnosis.sh does the interpreting.
    warn "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   no default route — the network has not given this Mac a way out."
    [ -n "$LINK_DHCP_ROUTER" ] && info "Router offered by DHCP: $LINK_DHCP_ROUTER"
  elif [ -n "$LINK_DEVICE" ]; then
    bad "Interface: $LINK_DEVICE is up but has no address — joined to nothing, or DHCP never answered."
  else
    bad "No active network interface — nothing is joined."
  fi

  # Additional gateways (multi-homed?)
  GW_COUNT="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2}' | sort -u | wc -l | tr -d ' ')"
  if [ "${GW_COUNT:-0}" -gt 1 ]; then
    warn "Multiple default gateways detected:"
    netstat -rn -f inet | awk '$1=="default"{print "      "$2"  ("$NF")"}' | log_pipe
  fi
}
