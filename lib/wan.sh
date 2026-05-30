# shellcheck shell=bash
# lib/wan.sh — NAT / WAN topology checks (v0.3).
#
# Three related probes about *what's between your LAN and the public
# internet*:
#   - wan_load_balancing_run: 3× parallel curl to ifconfig.co; flags
#     multiple ASNs / IPs (dual-WAN, CGNAT round-robin). Rule WAN-1/WAN-1b.
#   - wan_double_nat_run: walks TRACE_LINES counting consecutive RFC1918
#     hops before the first CGNAT (100.64/10) or public address. Rule NAT-1.
#   - wan_upnp_run: probes UPnP via `upnpc -s` or raw SSDP, optional
#     NAT-PMP fallback to gateway:5351. Rule UP-1.
#
# Reads:  QUICK, PUBLIC_OK, TRACE_LINES, GATEWAY
# Writes: WAN_LB_ASNS, WAN_LB_IPS, WAN_LB_ACTIVE,
#         WAN_DOUBLE_NAT, WAN_DOUBLE_NAT_CHAIN,
#         WAN_UPNP_STATE, WAN_UPNP_DEVICE, WAN_UPNP_URL, WAN_UPNP_TESTED_VIA
# Entry:  wan_load_balancing_run, wan_double_nat_run, wan_upnp_run,
#         wan_diagnosis_run

# ── 18. Dual-WAN / load-balancing probe ─────────────────────────────────
wan_load_balancing_run() {
  [ "$QUICK" -eq 0 ]     || return 0
  [ "$PUBLIC_OK" -eq 1 ] || return 0

  hdr "WAN load-balancing probe"
  local tmp i resp asn ip
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-wan.XXXXXX")"
  for i in 1 2 3; do
    curl -s -m 4 https://ifconfig.co/json > "$tmp/probe-$i.json" 2>/dev/null &
  done
  wait
  local asns="" ips=""
  for i in 1 2 3; do
    resp="$(cat "$tmp/probe-$i.json" 2>/dev/null)"
    [ -z "$resp" ] && continue
    asn="$(printf '%s' "$resp" | sed -n 's/.*"asn": *"\([^"]*\)".*/\1/p')"
    ip="$(printf '%s' "$resp"  | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')"
    [ -n "$asn" ] && case " $asns " in *" $asn "*) ;; *) asns="${asns:+$asns }$asn" ;; esac
    [ -n "$ip" ]  && case " $ips "  in *" $ip "*)  ;; *) ips="${ips:+$ips }$ip"   ;; esac
  done
  rm -rf "$tmp"
  WAN_LB_ASNS="$asns"
  WAN_LB_IPS="$ips"

  local n_asn n_ip
  n_asn="$(printf '%s' "$asns" | awk '{print NF}')"
  n_ip="$(printf '%s' "$ips"   | awk '{print NF}')"
  if [ -z "$asns" ] || [ "${n_asn:-0}" -eq 0 ]; then
    info "Could not run the dual-WAN probe (no JSON response)."
  elif [ "$n_asn" -gt 1 ]; then
    WAN_LB_ACTIVE=1
    warn "Multiple ASNs observed across 3 probes: $asns"
    info "Public IPs: $ips"
  elif [ "$n_ip" -gt 1 ]; then
    info "Single ASN ($asns) but multiple public IPs: $ips — likely CGNAT round-robin."
  else
    ok "Single egress ASN ($asns), single IP ($ips) — no load-balancing detected."
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar WAN_LB_ASNS "$WAN_LB_ASNS"
    setvar WAN_LB_IPS "$WAN_LB_IPS"
    setvar WAN_LB_ACTIVE "$WAN_LB_ACTIVE"
  fi
}

# ── 19. Double-NAT detection ────────────────────────────────────────────
# Walks TRACE_LINES counting consecutive RFC1918 hops before the first
# CGNAT or public address. Pure parsing; no extra network call.
wan_double_nat_run() {
  hdr "NAT topology"
  if [ -z "$TRACE_LINES" ]; then
    info "No traceroute data — skipping double-NAT analysis."
    return 0
  fi
  local chain
  chain="$(printf '%s' "$TRACE_LINES" | _wan_count_rfc1918_chain)"
  local n
  n="$(printf '%s' "$chain" | awk '{print NF}')"
  WAN_DOUBLE_NAT_CHAIN="$chain"
  if [ "${n:-0}" -gt 1 ]; then
    WAN_DOUBLE_NAT=1
    warn "Double-NAT detected: $n consecutive RFC1918 hops before the first public address."
    info "Chain: $chain"
    info "UPnP / port-forwarding from apps usually fails through double-NAT."
  elif [ "${n:-0}" -eq 1 ]; then
    ok "Single RFC1918 hop ($chain) before public — no double-NAT."
  else
    info "No RFC1918 hops in the traceroute path."
  fi
}

# Helper: read "n|ip|rtt" lines on stdin, print the consecutive RFC1918 IPs
# at the start of the path (stopping at the first CGNAT 100.64/10 or
# public address). Space-separated single line.
_wan_count_rfc1918_chain() {
  awk -F'|' '
    function is_rfc1918(ip,    a) {
      n_oct = split(ip, a, ".")
      if (n_oct != 4) return 0
      if (a[1] == 10) return 1
      if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) return 1
      if (a[1] == 192 && a[2] == 168) return 1
      return 0
    }
    {
      ip = $2
      if (is_rfc1918(ip)) {
        chain = chain (chain ? " " : "") ip
      } else {
        exit
      }
    }
    END { print chain }
  '
}

# ── 20. UPnP / NAT-PMP status ───────────────────────────────────────────
wan_upnp_run() {
  [ "$QUICK" -eq 0 ] || return 0

  hdr "UPnP / NAT-PMP status"
  # (a) Prefer miniupnpc's upnpc -s — gives device name + URL when present.
  # miniupnpc's label set varies across versions: older builds use `desc:` and
  # `st:`, current Tahoe Homebrew build emits `Found valid IGD :` plus a URL
  # on its own line. Treat any IGD/UPnP token as a positive signal, then
  # grep out the URL and a label-ish line best-effort.
  if command -v upnpc >/dev/null 2>&1; then
    local upnpc_out
    upnpc_out="$(with_timeout 5 upnpc -s 2>/dev/null || true)"
    if printf '%s' "$upnpc_out" | grep -qiE 'IGD|InternetGatewayDevice|UPnP device'; then
      WAN_UPNP_STATE="enabled"
      WAN_UPNP_TESTED_VIA="miniupnpc"
      # Extract the IGD description URL. miniupnpc's own help banner
      # contains a https://miniupnp.tuxfamily.org/ link, so filter to
      # URLs that look like an IGD endpoint: either a private-IP host
      # (RFC1918 / link-local) or a path ending in .xml.
      WAN_UPNP_URL="$(printf '%s\n' "$upnpc_out" \
        | grep -oE 'https?://[^[:space:]]+' \
        | grep -E 'https?://(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)|\.xml' \
        | head -1)"
      # Device label: prefer the service-type line (`st:` in miniupnpc
      # output, e.g. "urn:schemas-upnp-org:device:InternetGatewayDevice:1"),
      # then "UPnP device:" or "Found valid IGD". Explicitly skip `desc:` —
      # that's the URL, captured separately.
      WAN_UPNP_DEVICE="$(printf '%s\n' "$upnpc_out" \
        | awk '
            BEGIN{IGNORECASE=1}
            /^[[:space:]]*st:[[:space:]]/         {sub(/^[[:space:]]*st:[[:space:]]*/, "");           print; exit}
            /^[[:space:]]*UPnP device:[[:space:]]/{sub(/^[[:space:]]*UPnP device:[[:space:]]*/, ""); print; exit}
            /^Found valid IGD/                    {sub(/^[[:space:]]+/, ""); print; exit}
          ')"
      [ -z "$WAN_UPNP_DEVICE" ] && WAN_UPNP_DEVICE="IGD (label not parsed)"
      if [ -n "$WAN_UPNP_URL" ]; then
        warn "UPnP IGD enabled: $WAN_UPNP_DEVICE at $WAN_UPNP_URL"
      else
        warn "UPnP IGD enabled: $WAN_UPNP_DEVICE"
      fi
      _wan_upnp_persist
      return 0
    fi
    WAN_UPNP_STATE="disabled"
    WAN_UPNP_TESTED_VIA="miniupnpc"
    ok "UPnP IGD: not present (miniupnpc probe)."
    _wan_upnp_persist
    return 0
  fi

  # (b) Raw SSDP M-SEARCH via nc -u. Fire a discovery packet, watch for a
  # LOCATION: header in the reply within 2 s.
  local ssdp_reply
  ssdp_reply="$(printf 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n' \
    | with_timeout 3 nc -u -w 2 239.255.255.250 1900 2>/dev/null || true)"
  if printf '%s' "$ssdp_reply" | grep -qi '^LOCATION:'; then
    WAN_UPNP_STATE="enabled"
    WAN_UPNP_TESTED_VIA="ssdp"
    WAN_UPNP_URL="$(printf '%s' "$ssdp_reply" | awk -F': ' 'tolower($1)=="location"{print $2; exit}' | tr -d '\r')"
    WAN_UPNP_DEVICE="IGD via SSDP"
    warn "UPnP IGD responded to SSDP M-SEARCH at ${WAN_UPNP_URL:-?}"
    info "Install miniupnpc (\`brew install miniupnpc\`) for richer status."
    _wan_upnp_persist
    return 0
  fi

  # (c) NAT-PMP probe to gateway:5351 as a last resort. Apple's AirPort
  # and most Asus/Netgear routers prefer NAT-PMP over UPnP.
  if [ -n "$GATEWAY" ]; then
    # Public-Address request: 1-byte version (0), 1-byte op (0).
    local natpmp_reply
    natpmp_reply="$(printf '\x00\x00' | with_timeout 2 nc -u -w 1 "$GATEWAY" 5351 2>/dev/null | xxd -p 2>/dev/null || true)"
    if [ -n "$natpmp_reply" ]; then
      WAN_UPNP_STATE="enabled"
      WAN_UPNP_TESTED_VIA="nat-pmp"
      WAN_UPNP_DEVICE="NAT-PMP responder"
      warn "Router responded to NAT-PMP on $GATEWAY:5351 — port-mapping is open."
      info "Install miniupnpc for richer status."
      _wan_upnp_persist
      return 0
    fi
  fi

  WAN_UPNP_STATE="disabled"
  WAN_UPNP_TESTED_VIA="ssdp"
  ok "UPnP / NAT-PMP: no IGD responded (good for security)."
  info "Tip: \`brew install miniupnpc\` for richer probe results."

  _wan_upnp_persist
}

# Single persistence point for the UPnP function — also called from the
# enabled branches above, which return early.
_wan_upnp_persist() {
  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar WAN_UPNP_STATE "$WAN_UPNP_STATE"
    setvar WAN_UPNP_DEVICE "$WAN_UPNP_DEVICE"
    setvar WAN_UPNP_URL "$WAN_UPNP_URL"
    setvar WAN_UPNP_TESTED_VIA "$WAN_UPNP_TESTED_VIA"
  fi
}

# Diagnosis hook — called from lib/diagnosis.sh. Emits WAN-1 / WAN-1b /
# NAT-1 / UP-1 rules per docs/DIAGNOSIS-RULES.md.
wan_diagnosis_run() {
  if [ "$WAN_LB_ACTIVE" -eq 1 ]; then
    add_diag warn "Outbound traffic is being load-balanced across multiple ISPs ($WAN_LB_ASNS). Often intentional, but it explains IP-rebinding TLS warnings and asymmetric-routing surprises."
  elif [ -n "$WAN_LB_ASNS" ]; then
    # Single ASN but multiple IPs — info-only nudge.
    local n_ip
    n_ip="$(printf '%s' "$WAN_LB_IPS" | awk '{print NF}')"
    if [ "${n_ip:-0}" -gt 1 ]; then
      add_diag info "Same ISP ($WAN_LB_ASNS) but multiple public IPs ($WAN_LB_IPS) — likely CGNAT round-robin."
    fi
  fi
  if [ "$WAN_DOUBLE_NAT" -eq 1 ]; then
    # Split the chain into "home-side" (192.168/16 + 172.16/12) and
    # "ISP-side transit" (10/8) so the user can see what they actually
    # control. The 10/8 hops are usually carrier transit and not actionable.
    local home_chain="" isp_chain="" h
    for h in $WAN_DOUBLE_NAT_CHAIN; do
      case "$h" in
        192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[01].*)
          home_chain="${home_chain:+$home_chain → }$h"
          ;;
        10.*)
          isp_chain="${isp_chain:+$isp_chain → }$h"
          ;;
      esac
    done
    local home_count isp_count
    home_count="$(printf '%s' "$home_chain" | awk -F' → ' 'NF{print NF; exit} {print 0}')"
    isp_count="$(printf '%s'  "$isp_chain"  | awk -F' → ' 'NF{print NF; exit} {print 0}')"
    if [ "${home_count:-0}" -gt 1 ]; then
      add_diag warn "Double-NAT: ${home_count} home routers in series (${home_chain})${isp_chain:+ before ISP transit ($isp_chain)}. UPnP/port-forwarding from apps will likely fail. Put the inner router in bridge/AP mode if you control it."
    elif [ "${isp_count:-0}" -gt 1 ]; then
      add_diag info "Your ISP uses RFC1918 (${isp_chain}) for internal transit before reaching public IP space. Not actionable from your end; mentioning for context."
    else
      add_diag warn "Double-NAT detected — RFC1918 chain to first public hop: $WAN_DOUBLE_NAT_CHAIN. UPnP/port-forwarding will likely fail."
    fi
  fi
  # UPnP state is already shown in its own section with a `warn`-styled
  # marker. We deliberately do NOT re-emit it in Diagnosis to avoid
  # duplicating the same info in two places.
}

