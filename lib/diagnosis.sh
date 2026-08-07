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
  hdr "What we found"

  # N1 — no usable network at all. Every rule below keys off a measurement
  # that only exists once there IS a link, so without this the most basic
  # failure mode (WiFi off, cable unplugged) fired zero rules and the run
  # ended with "Nothing obviously wrong — your network looks healthy" and
  # exit 0, on a machine with no network whatsoever.
  if [ -z "$GATEWAY" ]; then
    add_diag critical N1 "Your Mac has no network connection at all — there's no default route, which means it isn't joined to a WiFi network and has no working ethernet link. Turn WiFi on and pick a network, or check that the ethernet cable is seated at both ends. Nothing else can be diagnosed until this is fixed."
  elif [ "$PUBLIC_OK" -eq 0 ] && [ -z "$GW_LOSS" ]; then
    # Reachable only from a focused run (--mtu-only), where the gateway
    # section is skipped so P1/P2 below can't evaluate.
    add_diag critical N1b "Your Mac has a router but nothing on the public internet responded. Re-run plain \`netdiag\` (without --mtu-only) for a full picture — it will tell you whether the problem is your router, your ISP, or DNS."
  fi

  # W1, W2, G1/G2 — WiFi quality and gateway loss interplay.
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -75 ]; then
    add_diag warn W1 "Your WiFi signal is weak (${WIFI_RSSI} dBm — anything below -75 is poor). Web pages will be slow and video calls will stutter. Try moving closer to the router, or switch to the 5 GHz network if your router broadcasts both bands."
  fi
  if [ -n "$WIFI_SNR" ] && [ "$WIFI_SNR" -lt 20 ]; then
    add_diag warn W2 "Other electronics or nearby WiFi networks are interfering with yours (signal-to-noise ratio ${WIFI_SNR} dB — below 20 dB is noisy). Try switching to a less crowded channel in your router settings."
  fi
  if [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge 20 ]; then
    if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -70 ]; then
      add_diag critical G1 "You're losing packets between your Mac and your router, and your WiFi signal is weak — the WiFi link is the bottleneck, not the router or the ISP. Move closer to the router or switch WiFi channel."
    else
      add_diag critical G2 "You're losing packets between your Mac and your router even though the WiFi signal is strong — the router itself is misbehaving. Try rebooting it (unplug for 30 seconds, plug back in)."
    fi
  fi

  # P1/P2 — public unreachable.
  if [ "$PUBLIC_OK" -eq 0 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -eq 0 ]; then
    if [ "$DNS_OK" -eq 0 ]; then
      add_diag critical P1 "Your local network is working but the wider internet is unreachable, and name lookups are also failing — likely a DNS or upstream-ISP outage. Try opening http://1.1.1.1 in a browser: if it loads, the problem is DNS; if not, it's the ISP."
    else
      add_diag critical P2 "Your local network is healthy and name lookups work, but no public website responds — almost certainly an outage on your ISP's side. Check their status page or call support."
    fi
  fi

  # D1 — partial DNS, internet reachable. DNS_LINES proves the check ran;
  # without it a skipped-DNS run would accuse a healthy resolver.
  if [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then
    add_diag warn D1 "The internet works but some name lookups are failing — your DNS server is flaky. Switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS."
  fi

  # B1/B2 — bufferbloat at gateway or ISP hop.
  case "${BUFFERBLOAT_GW_GRADE:-}" in
    C)   add_diag warn B1 "Your router gets a bit sluggish under load — when something is downloading or uploading heavily, calls and games will feel laggy (extra +${BUFFERBLOAT_GW_DELTA} ms delay, bufferbloat grade C). Fix: enable \"Smart Queue Management\" or \"QoS\" in your router's admin page." ;;
    D|F) add_diag critical B1 "Your router chokes under load — whenever someone's downloading or uploading, Zoom / FaceTime / WhatsApp calls will glitch and games will lag badly (extra +${BUFFERBLOAT_GW_DELTA} ms delay, bufferbloat grade ${BUFFERBLOAT_GW_GRADE}). Fix: enable \"Smart Queue Management\" or \"QoS\" in your router's admin page, or replace the router with one that supports it." ;;
  esac
  case "${BUFFERBLOAT_INET_GRADE:-}" in
    C)   add_diag warn B2 "The bottleneck under heavy use is your ISP's equipment, not your router (+${BUFFERBLOAT_INET_DELTA} ms extra delay under load, bufferbloat grade C). Try a modem firmware update if you control it; otherwise this is the ISP's responsibility." ;;
    D|F) add_diag critical B2 "Your ISP's equipment is the bottleneck — under load your connection adds +${BUFFERBLOAT_INET_DELTA} ms of delay (bufferbloat grade ${BUFFERBLOAT_INET_GRADE}), enough to ruin voice/video calls and multiplayer games. Call your ISP and ask about firmware updates or a plan with better latency." ;;
  esac

  # M1 — path MTU below 1500.
  if [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt 1400 ]; then
    add_diag critical M1 "Most websites won't load fully — your network is silently dropping anything bigger than ${MTU_EFFECTIVE} bytes per packet. Cause is usually a VPN or DSL link that hasn't been configured to tell other devices about the smaller size. Disconnect any VPN; if it persists, check your router's WAN settings (technical: path MTU ${MTU_EFFECTIVE} — needs MSS clamping)."
  elif [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt 1500 ]; then
    add_diag warn M1 "Some websites load fine and others hang forever loading — your network is silently dropping packets above ${MTU_EFFECTIVE} bytes. Usually caused by a VPN, a tunneled connection, or a DSL link. Try disconnecting any VPN; if it persists, ask your ISP or check your router's WAN-MTU / MSS-clamping setting."
  fi

  # MT1 — first lossy hop.
  if [ -n "$MTR_FIRST_LOSSY_HOP" ]; then
    add_diag warn MT1 "Packet loss starts at $MTR_FIRST_LOSSY_HOP — that hop on the path to the internet is dropping packets. Hops after it usually inherit the problem rather than adding their own. Whoever owns that hop (your router, your ISP, or a transit network) needs to look at it."
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
      add_diag warn V6-1 "Big sites (Google, YouTube, Cloudflare-hosted apps) feel sluggish for the first second of every page load — your network has a half-working modern-internet (IPv6) setup. Your Mac tries the new way, waits ~250 ms for it to fail, then falls back to the old way. Reboot the router; if it persists, ask your ISP whether IPv6 is actually enabled (technical: loss ${IPV6_PING_LOSS}%, AAAA ${aaaa_str}, TCP6 ${tcp6_str} — Happy Eyeballs is masking the failure)."
    fi
  fi

  # TCP-1 — TCP works, ICMP is filtered.
  if [ "$TCP_REACH_ANY_OK" -eq 1 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge 50 ]; then
    add_diag info TCP-1 "Actual connections work fine, only the \"ping\" tests fail (${GW_LOSS}% loss to the gateway) — something on the path is blocking pings but not real traffic. Common on hotel WiFi, corporate networks, and some ISPs. The network is up; don't worry about the ping numbers above."
  fi

  # WS-1 — congested WiFi channel.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt 3 ]; then
    add_diag warn WS-1 "Your WiFi channel (${WIFI_SCAN_CURRENT_CHANNEL}) is shared with ${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} neighbouring networks — they all interfere with each other. Switch to a less-crowded channel in your router's WiFi settings (good 5 GHz choices most routers don't pick automatically: 149, 153, 157, 161)."
  fi

  # WD-1 — WiFi flapping.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_DISCONNECT_COUNT" -gt 3 ]; then
    add_diag warn WD-1 "Your WiFi keeps dropping and reconnecting (${WIFI_DISCONNECT_COUNT} times in the past hour). Common causes: weak signal at your desk, your Mac bouncing between two routers / mesh nodes that overlap, or a router firmware bug. If you have multiple WiFi points, check whether they're set up as a proper mesh."
  fi

  # NT-1 — system clock significantly off. Sub-second drift is round-trip
  # noise and not worth reporting; > 30 s breaks TLS everywhere; the
  # 1-30 s band is a soft warning since some apps tolerate it and some don't.
  if [ -n "$NTP_DRIFT_S" ] && awk -v d="$NTP_DRIFT_S" 'BEGIN{exit !((d<0?-d:d) > 30)}'; then
    add_diag critical NT-1 "Your Mac's clock is off by ${NTP_DRIFT_S} seconds — every secure website (anything starting with https://) will refuse to connect because clock-based certificate checks will fail. Fix: open System Settings → General → Date & Time and turn \"Set date and time automatically\" on."
  elif [ -n "$NTP_DRIFT_S" ] && awk -v d="$NTP_DRIFT_S" 'BEGIN{exit !((d<0?-d:d) > 1)}'; then
    add_diag warn NT-1 "Your Mac's clock is off by ${NTP_DRIFT_S} seconds. Most apps will be fine but some authenticated services (banking apps, work VPNs) may refuse to connect. Turn on \"Set date and time automatically\" in System Settings → General → Date & Time if this persists."
  fi

  # DI-1 — duplicate IP / incomplete gateway ARP.
  if [ "$ARP_GW_INCOMPLETE" -eq 1 ]; then
    add_diag critical DI-1 "Your Mac can't find your router on the local network — the connection between them is broken at the hardware layer. Check the ethernet cable, the WiFi connection, or that the right router is set as the default. Nothing else above this matters until this is fixed."
  fi
  if [ -n "${ARP_DUPLICATE_IPS//[[:space:]]/}" ]; then
    add_diag critical DI-2 "Another device on your network is using the same IP address as one of these: ${ARP_DUPLICATE_IPS}. Both devices will randomly steal each other's traffic. Cause is usually a manually-set IP that collides with one the router handed out, or a second router on the network. Find and fix the duplicate."
  fi

  # DH-1 — DHCP lease expires soon.
  if [ -n "$DHCP_TIME_REMAINING_S" ] && [ "$DHCP_TIME_REMAINING_S" -gt 0 ] && [ "$DHCP_TIME_REMAINING_S" -lt 3600 ]; then
    add_diag warn DH-1 "Your Mac's network-address lease from the router expires in $((DHCP_TIME_REMAINING_S / 60)) minutes. Normally it renews automatically, but if your router is rebooting or out of addresses at that moment, you'll suddenly lose the network with no warning. Keep an eye out."
  fi

  # DH-2 — DHCP vs system DNS mismatch.
  if [ -n "$DHCP_DNS_SERVERS" ] && [ -n "$SYS_RES" ] && ! printf '%s' "$DHCP_DNS_SERVERS" | grep -qF "$SYS_RES"; then
    add_diag info DH-2 "Your router suggested $DHCP_DNS_SERVERS for name lookups, but your Mac is using $SYS_RES instead — somebody manually overrode it. Fine if you did it on purpose (1.1.1.1 and 8.8.8.8 are common choices); surprising if you didn't."
  fi

  # WAN-1 / WAN-1b / NAT-1 / UP-1 live in lib/wan.sh's diagnosis hook so
  # this file stays scoped to the older rules. The hook is a no-op stub
  # until the NAT/WAN section ships.
  if declare -f wan_diagnosis_run >/dev/null 2>&1; then
    wan_diagnosis_run
  fi

  MOST_LIKELY_ROOT_CAUSE=""
  if [ "${#DIAG[@]}" -eq 0 ]; then
    ok "Nothing obviously wrong — your network looks healthy."
    return 0
  fi
  # Sort by severity descending (critical → warn → info), preserving insertion
  # order within each severity. First line emitted becomes most_likely_root_cause.
  # Each diagnosis is rendered as a wrapped paragraph: first line gets the
  # status icon + 1 space, continuation lines align under the text (4-col
  # indent). Blank line between diagnoses for readability.
  local s i first=1
  for s in critical warn info; do
    for i in "${!DIAG[@]}"; do
      if [ "${DIAG_SEV[$i]}" = "$s" ]; then
        [ -z "$MOST_LIKELY_ROOT_CAUSE" ] && MOST_LIKELY_ROOT_CAUSE="${DIAG[$i]}"
        [ "$first" -eq 0 ] && say ""
        first=0
        _print_diagnosis_paragraph "$s" "${DIAG_RULE[$i]}" "${DIAG[$i]}"
        DIAGNOSIS_LINES+="${s}|${DIAG_RULE[$i]}|${DIAG[$i]}"$'\n'
      fi
    done
  done
}

# Render one diagnosis as a wrapped paragraph: status icon on the first
# line, subsequent lines indented to align under the text. Wrap at 76 cols
# so 80-col terminals stay clean.
_print_diagnosis_paragraph() {
  local sev="$1" rule="$2" text="$3"
  local icon
  case "$sev" in
    critical) icon="${C_RED}✗${C_RESET}" ;;
    warn)     icon="${C_YEL}⚠${C_RESET}" ;;
    info)     icon="${C_DIM}·${C_RESET}" ;;
    *)        icon="·" ;;
  esac
  # Expert mode names the rule so a reader can look up the threshold in
  # docs/DIAGNOSIS-RULES.md. Default output stays prose-only — a rule ID
  # means nothing to the person the plain-English rewrite was written for.
  if [ "$EXPERT" -eq 1 ] && [ -n "$rule" ]; then
    text="[${rule}] ${text}"
  fi
  # fmt -w 70 leaves 6 chars (2 indent + icon + 3 spaces of breathing room)
  # for the prefix on each line. NR==1 gets the icon prefix; later lines
  # get a 4-space indent to align under the icon's text column.
  printf '%s\n' "$text" | fmt -w 70 \
    | awk -v icon="  $icon " 'NR==1{print icon $0; next} {print "    " $0}' \
    | while IFS= read -r line; do say "$line"; done
}
