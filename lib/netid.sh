# shellcheck shell=bash
# lib/netid.sh — derive a stable identity for the network we're on.
#
# Why this exists: ~/net-diag/baseline.jsonl is one flat stream of every
# run ever recorded. On a laptop that means home, office, and café runs
# are all compared against each other, so helpers/baseline.py flagged
# "gateway RTT ×4 spike", "ISP changed", "WiFi channel changed" and "path
# MTU changed" on essentially every location change — each one an
# add_diag warn, each one bumping the exit code to 1. The regressions are
# real signal on a desktop and pure noise on a laptop.
#
# Scoping history by network identity fixes that: a run is only compared
# against prior runs on the *same* network.
#
# Identity is a readable composite rather than a hash — when a baseline
# comparison looks wrong, you want to be able to read the key straight out
# of the JSON and see why two runs did or didn't match.
#
# Preference order, most stable first:
#   1. gateway MAC   — survives DHCP re-leases and SSID renames, and
#                      distinguishes two networks sharing 192.168.1.0/24
#   2. SSID          — stable and human-meaningful, but macOS redacts it
#                      without Location Services, and two sites can share
#                      one (corporate SSIDs, ISP-default names)
#   3. gateway IP    — weakest: 192.168.1.1 collides constantly. Used only
#                      when neither of the above is available.
#
# Reads:  IS_WIFI, WIFI_SSID, GW_MAC, GATEWAY, INTERFACE
# Writes: NETWORK_ID, NETWORK_LABEL, NETWORK_GROUP
# Entry:  netid_run

netid_run() {
  local kind="lan" ssid="" parts=""
  [ "$IS_WIFI" -eq 1 ] && kind="wifi"

  # macOS reports "<redacted>" rather than an empty string when the caller
  # lacks Location Services; treat it as "unknown", not as a literal name
  # — otherwise every redacted machine shares one identity.
  if [ -n "$WIFI_SSID" ] && [ "$WIFI_SSID" != "<redacted>" ]; then
    ssid="$WIFI_SSID"
  fi

  [ -n "$ssid" ]    && parts="ssid=$ssid"
  [ -n "$GW_MAC" ]  && parts="${parts:+$parts,}mac=$GW_MAC"
  # Only fall back to the gateway IP when nothing stronger identified the
  # network — on its own it's a near-guaranteed collision across sites.
  if [ -z "$parts" ] && [ -n "$GATEWAY" ]; then
    parts="gw=$GATEWAY"
  fi

  # The canonical history GROUP KEY for this network — the key
  # helpers/history.py's group_key() derives from stored records, so a
  # live consumer (the monitor, the GUI) can join straight onto
  # --history's network groups without post-processing the raw id.
  # Preference mirrors group_key exactly: MAC (lowercased) beats gateway
  # IP beats SSID. netid_run and group_key are a pair — change one,
  # change the other; tests/test_history.bats runs both over the same
  # ids and fails the build if they drift apart.
  if [ -n "$GW_MAC" ]; then
    NETWORK_GROUP="mac:${GW_MAC,,}"
  elif [ -n "$GATEWAY" ]; then
    NETWORK_GROUP="gw:$GATEWAY"
  elif [ -n "$ssid" ]; then
    NETWORK_GROUP="ssid:$ssid"
  else
    NETWORK_GROUP=""
  fi

  if [ -z "$parts" ]; then
    NETWORK_ID=""
    NETWORK_LABEL="unknown network"
  else
    NETWORK_ID="${kind}:${parts}"
    if [ -n "$ssid" ]; then
      NETWORK_LABEL="$ssid"
    elif [ "$kind" = "wifi" ]; then
      NETWORK_LABEL="WiFi (SSID hidden by macOS)"
    else
      NETWORK_LABEL="wired via ${GATEWAY:-?}"
    fi
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar NETWORK_ID "$NETWORK_ID"
    setvar NETWORK_LABEL "$NETWORK_LABEL"
    setvar NETWORK_GROUP "$NETWORK_GROUP"
  fi
}
