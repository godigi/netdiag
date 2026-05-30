# shellcheck shell=bash
# lib/iface.sh — local interface, IP, default gateway.
#
# Writes: INTERFACE, LOCAL_IP, GATEWAY, GW_COUNT
# Entry:  iface_run

iface_run() {
  hdr "Local network"
  INTERFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  GATEWAY="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  LOCAL_IP=""
  if [ -n "$INTERFACE" ]; then
    LOCAL_IP="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null)"
  fi
  if [ -n "$INTERFACE" ] && [ -n "$GATEWAY" ]; then
    ok "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   Gateway: $GATEWAY"
  else
    bad "No default route — no network configured."
  fi

  # Additional gateways (multi-homed?)
  GW_COUNT="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2}' | sort -u | wc -l | tr -d ' ')"
  if [ "${GW_COUNT:-0}" -gt 1 ]; then
    warn "Multiple default gateways detected:"
    netstat -rn -f inet | awk '$1=="default"{print "      "$2"  ("$NF")"}' | log_pipe
  fi
}
