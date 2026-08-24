# shellcheck shell=bash
# lib/vpn.sh — VPN active? Detects managed VPNs, Tailscale, and utun/wg
# default routes.
#
# Reads:  INTERFACE
# Writes: VPN_ACTIVE, VPN_TYPE, VPN_NAME
# Entry:  vpn_detect, vpn_run

vpn_detect() {
  VPN_ACTIVE=0
  VPN_TYPE=""
  VPN_NAME=""
  # (a) Managed VPNs surface as Connected entries in scutil --nc list.
  local scutil_nc
  scutil_nc="$(with_timeout 5 scutil --nc list 2>/dev/null || true)"
  if printf '%s' "$scutil_nc" | grep -q '(Connected)'; then
    VPN_ACTIVE=1
    VPN_TYPE="managed"
    VPN_NAME="$(printf '%s' "$scutil_nc" | awk -F'"' '/\(Connected\)/{print $2; exit}')"
  fi
  # (b) Tailscale exposes a JSON status; BackendState=="Running" means connected.
  if [ "$VPN_ACTIVE" -eq 0 ] && command -v tailscale >/dev/null 2>&1 \
     && command -v jq >/dev/null 2>&1; then
    local ts_json
    ts_json="$(with_timeout 5 tailscale status --json 2>/dev/null || true)"
    if printf '%s' "$ts_json" | jq -e '.BackendState=="Running"' >/dev/null 2>&1; then
      VPN_ACTIVE=1
      VPN_TYPE="tailscale"
      VPN_NAME="tailscale ($(printf '%s' "$ts_json" | jq -r .Self.HostName 2>/dev/null))"
    fi
  fi
  # (c) Default route via utun* / wg* — most reliable WireGuard-style signal.
  # macOS always has spare utun interfaces, so existence alone is meaningless;
  # we want one that's actually carrying the default route.
  if [ "$VPN_ACTIVE" -eq 0 ] && printf '%s' "$INTERFACE" | grep -qE '^(utun|wg)'; then
    VPN_ACTIVE=1
    VPN_TYPE="utun-route"
    VPN_NAME="$INTERFACE"
  fi

}

vpn_run() {
  hdr "VPN"
  vpn_detect
  if [ "$VPN_ACTIVE" -eq 1 ]; then
    bad "VPN active: $VPN_NAME ($VPN_TYPE)"
    info "Heads-up: the 'gateway' below is the VPN endpoint, not your LAN router."
  else
    ok "No VPN active."
  fi
}
