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
# Reads:  IS_WIFI, WIFI_SSID, GW_MAC, GATEWAY, LINK_DHCP_ROUTER, INTERFACE
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
  #
  # LINK_DHCP_ROUTER is the second fallback rather than a peer of GATEWAY
  # because it names the same box by a weaker route: the DHCP server said
  # so, rather than the kernel having installed a route to it. It exists
  # here because without it every routeless run filed itself under the
  # synthetic "unknown" network — six of twelve consecutive runs on this
  # developer's machine — which put "no network at all" verdicts into a
  # history bucket shared by every other routeless run on every other
  # network, and kept them out of the bucket for the network actually
  # being diagnosed.
  if [ -z "$parts" ]; then
    if [ -n "$GATEWAY" ]; then
      parts="gw=$GATEWAY"
    elif [ -n "${LINK_DHCP_ROUTER:-}" ]; then
      parts="gw=$LINK_DHCP_ROUTER"
    fi
  fi

  # The canonical history GROUP KEY for this network — the key
  # helpers/history.py's group_key() derives from stored records, so a
  # live consumer (the monitor, the GUI) can join straight onto
  # --history's network groups without post-processing the raw id.
  # Preference mirrors group_key exactly: MAC (lowercased), then SSID,
  # then gateway IP. netid_run and group_key are a pair — change one,
  # change the other; tests/test_history.bats runs both over the same
  # ids and fails the build if they drift apart.
  #
  # The order is SSID-before-gateway-IP for the reason this file's own
  # header gives: a gateway IP "collides constantly" (192.168.1.1 is
  # every third home network), while an SSID is at least
  # human-meaningful. This block previously read GATEWAY before ssid,
  # which contradicted both that header and group_key: on Wi-Fi with a
  # visible SSID but no gateway MAC — ARP not yet resolved, or a captive
  # network — netid_run emitted `gw:192.168.1.1` while group_key derived
  # `ssid:Cafe` from the very id netid_run had just written, so the join
  # this key exists to enable silently failed. The old test's fixtures
  # never carried both an SSID and a gateway at once, so nothing caught
  # it.
  #
  # `tr` rather than `${GW_MAC,,}`: that expansion is bash 4+, and under
  # macOS's system bash 3.2 it is a fatal runtime "bad substitution"
  # that kills the surrounding subshell — which is what made
  # tests/test_history.bats fail with "netid_group failed" rather than
  # with a value mismatch. CLAUDE.md requires this code run under both
  # zsh and Homebrew bash 5, but a construct that detonates on the
  # system bash is a landmine regardless of the declared shebang.
  if [ -n "$GW_MAC" ]; then
    NETWORK_GROUP="mac:$(printf '%s' "$GW_MAC" | tr '[:upper:]' '[:lower:]')"
  elif [ -n "$ssid" ]; then
    NETWORK_GROUP="ssid:$ssid"
  elif [ -n "$GATEWAY" ]; then
    NETWORK_GROUP="gw:$GATEWAY"
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
