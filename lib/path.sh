# shellcheck shell=bash
# lib/path.sh — what else is sitting in the path, besides the network.
#
# One check for what looked like five unrelated features, because they
# are one bug wearing different clothes: **netdiag assumes the default
# route is the path its traffic takes.** Split-tunnel VPNs, PAC proxies,
# DoH resolvers, per-app proxies and NetworkExtension content filters
# each break that assumption, and each silently invalidates a *different
# subset* of the report — while every measurement above still reads as a
# clean description of "the network".
#
# So this file does not diagnose faults. It enumerates actors and says
# which measurements they undermine. A content filter is not a problem;
# a content filter you did not know was in the path, while netdiag tells
# you your router is fine, is how an afternoon gets lost.
#
# Everything here is unprivileged and cheap (~20-100 ms each), which is
# why it runs in the parallel batch rather than earning its own phase.
#
# Reads:  nothing
# Writes: PATH_SPLIT_TUNNEL, PATH_SPLIT_TUNNEL_IFACES, PATH_PROXY,
#         PATH_PROXY_DETAIL, PATH_FILTERS, PATH_FILTER_COUNT
# Entry:  path_run

# ── Split-tunnel VPN [VPN-2] ─────────────────────────────────────────────
#
# VPN-1 fires on the *default route*. A corporate split-tunnel VPN
# deliberately does not take it: it installs routes for the company's
# prefixes only. So netdiag reports a perfectly healthy network while
# every work application is broken, and says nothing about the one
# component that is failing.
#
# Existence of a utun interface means nothing — this developer's Mac has
# six, all up, all carrying no routes, and macOS creates them as a matter
# of course. Only a *route* pointing at one is evidence.

# Interfaces carrying non-default routes, from `netstat -rn -f inet`
# output ($1), space-separated and deduped; empty when there are none.
#
# Skips `default` (that is VPN-1's business, not this rule's) and skips
# the header lines, which have no Netif column to speak of.
path_parse_tunnel_routes() {
  printf '%s\n' "$1" | awk '
    $1 == "Destination" { started = 1; next }
    !started { next }
    $1 == "default" { next }
    {
      # Netif is the second-to-last column when Expire is present and the
      # last when it is not, so the interface is found by shape rather
      # than by index.
      for (i = NF; i >= 1; i--) {
        if ($i ~ /^(utun|ipsec|ppp|wg)[0-9]+$/) {
          if (!($i in seen)) { seen[$i] = 1; order[++n] = $i }
          break
        }
      }
    }
    END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), order[i] }'
}

# ── Web proxy / PAC [PX-1] ───────────────────────────────────────────────
#
# On a managed Mac a PAC file decides which destinations go direct and
# which go through a proxy, so tcp_reach's direct connections test a path
# real traffic never uses. Nothing in netdiag read these before.

# "yes"/"" from a `networksetup -getwebproxy`-style block ($1).
# Both the manual-proxy and auto-proxy forms report `Enabled: Yes`.
path_parse_proxy_enabled() {
  printf '%s\n' "$1" | awk -F': ' '
    /^Enabled:/ { if ($2 ~ /^[Yy]es/) { print "yes"; exit } }'
}

# "host:port" (or the PAC URL) from the same block ($1), or empty.
path_parse_proxy_detail() {
  printf '%s\n' "$1" | awk -F': ' '
    /^Server:/ { srv = $2 }
    /^Port:/   { port = $2 }
    /^URL:/    { if ($2 != "(null)") url = $2 }
    END {
      if (url != "") { print url }
      else if (srv != "") { print srv (port != "" && port != "0" ? ":" port : "") }
    }'
}

# ── Content filters [FW-1] ───────────────────────────────────────────────
#
# Zscaler, Netskope, Cloudflare WARP, Little Snitch and LuLu install
# NetworkExtension content filters that sit in the datapath. When one
# misbehaves it *is* the fault, and netdiag would otherwise attribute its
# symptoms to the router or the ISP.
#
# Named, never accused: the wording has to read as "here is something
# else in the path", because these are usually working exactly as their
# owner intended and a network tool crying wolf about corporate security
# software is worse than silence.

# Network-extension bundle IDs from `systemextensionsctl list` output
# ($1), space-separated; empty when none are installed.
#
# The output is grouped under `--- com.apple.system_extension.<kind>`
# headers, with a `enabled active teamID bundleID (version) name [state]`
# table under each. Only the network_extension group is of interest —
# this machine has camera and driver extensions installed, and neither is
# in the datapath.
path_parse_network_extensions() {
  printf '%s\n' "$1" | awk '
    /^---[[:space:]]+com\.apple\.system_extension\./ {
      in_net = ($0 ~ /network_extension/)
      next
    }
    !in_net { next }
    /^enabled[[:space:]]+active/ { next }        # the column header
    {
      # Fields: [enabled] [active] teamID bundleID (version) name [state].
      # The bundle ID is the field immediately before the parenthesised
      # version, which is stable across the presence or absence of the
      # two leading asterisk columns.
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\(/ && i > 1) {
          if (!($(i-1) in seen)) { seen[$(i-1)] = 1; order[++n] = $(i-1) }
          break
        }
      }
    }
    END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), order[i] }'
}

# ── Entry ────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034
path_run() {
  PATH_SPLIT_TUNNEL=0; PATH_SPLIT_TUNNEL_IFACES=""
  PATH_PROXY=0; PATH_PROXY_DETAIL=""
  PATH_FILTERS=""; PATH_FILTER_COUNT=0

  hdr "What else is in the path"

  PATH_SPLIT_TUNNEL_IFACES="$(path_parse_tunnel_routes \
    "$(with_timeout 5 netstat -rn -f inet 2>/dev/null || true)")"
  if [ -n "$PATH_SPLIT_TUNNEL_IFACES" ]; then
    PATH_SPLIT_TUNNEL=1
    info "Tunnel routes via: $PATH_SPLIT_TUNNEL_IFACES"
  fi

  # Proxies are per-service, and the service carrying the link is the
  # only one whose proxy settings apply to this run's measurements.
  if [ -n "${LINK_SERVICE:-}" ]; then
    local web auto
    web="$(with_timeout 5 networksetup -getwebproxy "$LINK_SERVICE" 2>/dev/null || true)"
    auto="$(with_timeout 5 networksetup -getautoproxyurl "$LINK_SERVICE" 2>/dev/null || true)"
    if [ "$(path_parse_proxy_enabled "$web")" = "yes" ]; then
      PATH_PROXY=1
      PATH_PROXY_DETAIL="$(path_parse_proxy_detail "$web")"
    elif [ "$(path_parse_proxy_enabled "$auto")" = "yes" ]; then
      PATH_PROXY=1
      PATH_PROXY_DETAIL="$(path_parse_proxy_detail "$auto")"
    fi
    [ "$PATH_PROXY" -eq 1 ] && info "Proxy: ${PATH_PROXY_DETAIL:-configured}"
  fi

  PATH_FILTERS="$(path_parse_network_extensions \
    "$(with_timeout 5 systemextensionsctl list 2>/dev/null || true)")"
  if [ -n "$PATH_FILTERS" ]; then
    # shellcheck disable=SC2086
    set -- $PATH_FILTERS
    PATH_FILTER_COUNT=$#
    info "Network filter extensions: $PATH_FILTERS"
  fi

  [ "$PATH_SPLIT_TUNNEL" -eq 0 ] && [ "$PATH_PROXY" -eq 0 ] \
    && [ "$PATH_FILTER_COUNT" -eq 0 ] \
    && info "Nothing else in the path — this report describes your network directly."

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar PATH_SPLIT_TUNNEL "$PATH_SPLIT_TUNNEL"
    setvar PATH_SPLIT_TUNNEL_IFACES "$PATH_SPLIT_TUNNEL_IFACES"
    setvar PATH_PROXY "$PATH_PROXY"
    setvar PATH_PROXY_DETAIL "$PATH_PROXY_DETAIL"
    setvar PATH_FILTERS "$PATH_FILTERS"
    setvar PATH_FILTER_COUNT "$PATH_FILTER_COUNT"
  fi
  return 0
}
