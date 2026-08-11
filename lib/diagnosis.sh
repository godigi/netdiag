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
# Rule names match docs/DIAGNOSIS-RULES.md. Every numeric cutoff lives in
# lib/thresholds.sh, not inline here, because lib/monitor.sh judges the
# same conditions between scans and the two must never disagree — a
# menu-bar dot that says "unstable" over a report that says "healthy"
# discredits both.

diagnosis_run() {
  hdr "What we found"

  # N1 — no usable network at all. Every rule below keys off a measurement
  # that only exists once there IS a link, so without this the most basic
  # failure mode (WiFi off, cable unplugged) fired zero rules and the run
  # ended with "Nothing obviously wrong — your network looks healthy" and
  # exit 0, on a machine with no network whatsoever.
  if [ -z "$GATEWAY" ]; then
    add_diag critical N1 "Your Mac has no network connection at all — there's no default route, which means it isn't joined to a WiFi network and has no working ethernet link. Turn WiFi on and pick a network, or check that the ethernet cable is seated at both ends. Nothing else can be diagnosed until this is fixed."
  elif [ "${PUBLIC_CHECKED:-0}" -eq 1 ] && [ "$PUBLIC_OK" -eq 0 ] && [ -z "$GW_LOSS" ]; then
    # Reachable only from a focused run (--mtu-only), where the gateway
    # section is skipped so P1/P2 below can't evaluate. PUBLIC_CHECKED
    # gates it because --wifi-only never runs public_run at all, and the
    # untouched PUBLIC_OK=0 default made this critical fire — exit 2 — on
    # a network whose internet was fine.
    local _rerun="Re-run plain \`netdiag\`"
    [ -n "${FOCUS:-}" ] && _rerun="$_rerun (without --${FOCUS}-only)"
    add_diag critical N1b "Your Mac has a router but nothing on the public internet responded. $_rerun for a full picture — it will tell you whether the problem is your router, your ISP, or DNS."
  fi

  # W1, W2, G1/G2 — WiFi quality and gateway loss interplay.
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt "$THRESH_WIFI_RSSI_WEAK_DBM" ]; then
    add_diag warn W1 "Your WiFi signal is weak (${WIFI_RSSI} dBm — anything below ${THRESH_WIFI_RSSI_WEAK_DBM} is poor). Web pages will be slow and video calls will stutter. Try moving closer to the router, or switch to the 5 GHz network if your router broadcasts both bands."
  fi
  if [ -n "$WIFI_SNR" ] && [ "$WIFI_SNR" -lt "$THRESH_WIFI_SNR_LOW_DB" ]; then
    add_diag warn W2 "Other electronics or nearby WiFi networks are interfering with yours (signal-to-noise ratio ${WIFI_SNR} dB — below ${THRESH_WIFI_SNR_LOW_DB} dB is noisy). Try switching to a less crowded channel in your router settings."
  fi
  if loss_at_least "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt "$THRESH_WIFI_RSSI_G1_DBM" ]; then
      add_diag critical G1 "You're losing packets between your Mac and your router, and your WiFi signal is weak — the WiFi link is the bottleneck, not the router or the ISP. Move closer to the router or switch WiFi channel."
    else
      add_diag critical G2 "You're losing packets between your Mac and your router even though the WiFi signal is strong — the router itself is misbehaving. Try rebooting it (unplug for 30 seconds, plug back in)."
    fi
  elif loss_at_least "$GW_LOSS" "$LOSS_WARN_PCT"; then
    # G3 — the band under G1/G2's critical floor. Previously this coloured
    # the Report card's Router row yellow and did nothing else: because
    # ok()/warn()/bad() are pure printers and only add_diag moves
    # MAX_SEVERITY, 15% loss to your own router exited 0 under the headline
    # "Nothing obviously wrong". At that rate every page load stalls on a
    # retransmit and video calls break up, which is precisely the state a
    # user describes as "the internet is down".
    add_diag warn G3 "Your Mac is losing about ${GW_LOSS}% of the packets it sends to your own router — not enough to break the connection outright, but enough that web pages stall for a second or two and video calls break up. On WiFi this is usually signal or interference: move closer, or switch channel. On ethernet, suspect the cable or the port."
  fi

  # P1/P2 — public unreachable. The gateway guard was `== 0` exactly until
  # G3 landed, which left a hole: an outage measured alongside 8% gateway
  # loss matched neither P1/P2 (loss was not 0) nor G1/G2 (loss was under
  # 20), so a total loss of internet produced no diagnosis at all. The
  # guard now means "the router is not the problem", not "the router is
  # flawless".
  if [ "$PUBLIC_OK" -eq 0 ] && loss_below "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
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
  if [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt "$THRESH_MTU_CRIT" ]; then
    add_diag critical M1 "Most websites won't load fully — your network is silently dropping anything bigger than ${MTU_EFFECTIVE} bytes per packet. Cause is usually a VPN or DSL link that hasn't been configured to tell other devices about the smaller size. Disconnect any VPN; if it persists, check your router's WAN settings (technical: path MTU ${MTU_EFFECTIVE} — needs MSS clamping)."
  elif [ -n "$MTU_EFFECTIVE" ] && [ "$MTU_EFFECTIVE" -lt "$THRESH_MTU_STANDARD" ]; then
    add_diag warn M1 "Some websites load fine and others hang forever loading — your network is silently dropping packets above ${MTU_EFFECTIVE} bytes. Usually caused by a VPN, a tunneled connection, or a DSL link. Try disconnecting any VPN; if it persists, ask your ISP or check your router's WAN-MTU / MSS-clamping setting."
  fi

  # MT1 — first lossy hop.
  if [ -n "$MTR_FIRST_LOSSY_HOP" ]; then
    add_diag warn MT1 "Packet loss starts at $MTR_FIRST_LOSSY_HOP — that hop on the path to the internet is dropping packets. Hops after it usually inherit the problem rather than adding their own. Whoever owns that hop (your router, your ISP, or a transit network) needs to look at it."
  fi

  # V6-1 — IPv6 broken while IPv4 works.
  if [ "$IPV6_AVAILABLE" -eq 1 ]; then
    local v6_broken=0 aaaa_str tcp6_str
    [ -n "$IPV6_PING_LOSS" ] && [ "${IPV6_PING_LOSS%.*}" -ge "$THRESH_IPV6_LOSS_PCT" ] && v6_broken=1
    [ "$IPV6_AAAA_OK" -eq 0 ] && v6_broken=1
    [ "$IPV6_TCP_OK" -eq 0 ] && v6_broken=1
    if [ "$v6_broken" -eq 1 ] && [ "$PUBLIC_OK" -eq 1 ]; then
      aaaa_str=$([ "$IPV6_AAAA_OK" -eq 1 ] && echo OK || echo FAIL)
      tcp6_str=$([ "$IPV6_TCP_OK" -eq 1 ] && echo OK || echo FAIL)
      add_diag warn V6-1 "Big sites (Google, YouTube, Cloudflare-hosted apps) feel sluggish for the first second of every page load — your network has a half-working modern-internet (IPv6) setup. Your Mac tries the new way, waits ~250 ms for it to fail, then falls back to the old way. Reboot the router; if it persists, ask your ISP whether IPv6 is actually enabled (technical: loss ${IPV6_PING_LOSS}%, AAAA ${aaaa_str}, TCP6 ${tcp6_str} — Happy Eyeballs is masking the failure)."
    fi
  fi

  # VPN-1 — a VPN is carrying the default route. info, never a fault: the
  # point is that every measurement below describes the tunnel rather than
  # the local link, so the user doesn't blame their router for the VPN.
  if [ "$VPN_ACTIVE" -eq 1 ]; then
    add_diag info VPN-1 "A VPN is carrying your traffic right now (${VPN_NAME:-$VPN_TYPE}). Everything measured above — router, latency, traceroute, speed — describes the tunnel and the VPN's exit server, not your own network. If something looks slow here, the VPN is as likely a cause as your ISP. Disconnect it and run netdiag again to see the underlying connection."
  fi

  # TCP-1 — TCP works, ICMP is filtered.
  if [ "$TCP_REACH_ANY_OK" -eq 1 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge "$THRESH_ICMP_FILTERED_LOSS_PCT" ]; then
    add_diag info TCP-1 "Actual connections work fine, only the \"ping\" tests fail (${GW_LOSS}% loss to the gateway) — something on the path is blocking pings but not real traffic. Common on hotel WiFi, corporate networks, and some ISPs. The network is up; don't worry about the ping numbers above."
  fi

  # ── L1 / L2 — internet-side packet loss ────────────────────────────────
  # The gap these close: INET_LOSS was measured, written to JSON, and used
  # to colour a Report-card row, but no rule ever read it. Only add_diag
  # moves MAX_SEVERITY, so 40% loss upstream of a clean router printed a
  # red "Latency" row directly above "Nothing obviously wrong — your
  # network looks healthy" and exited 0.
  #
  # P1/P2 cannot cover this: they require public.ok == false, and under
  # heavy-but-partial loss curl still succeeds — TCP just retransmits its
  # way through. That is exactly the state a user calls "the internet is
  # down": everything technically works, nothing finishes.

  # ICMP-1 first. Total loss to *both* public targets while curl and TCP
  # both succeed is not an outage — real 100% loss would take curl with
  # it. It is an ISP or middlebox dropping ICMP wholesale. Without this
  # guard L1 would tell those users their ISP is down on a working link,
  # which is the same false-critical shape as the ping6 bug in v0.5.2.
  local _icmp_filtered=0
  if [ "$PUBLIC_OK" -eq 1 ] && [ "$TCP_REACH_ANY_OK" -eq 1 ] \
     && loss_at_least "$INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT" \
     && loss_at_least "$INET_LOSS_ALT" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
    _icmp_filtered=1
    add_diag info ICMP-1 "Ping to the outside world fails completely (${INET_TARGET} and ${INET_TARGET_ALT} both at 100%), but real connections — websites, DNS, TCP — all work. Something upstream is blocking ping specifically, which some ISPs and most corporate or hotel networks do on purpose. Your internet is fine; the latency numbers above just can't be measured."
  fi

  # loss_below rather than ! loss_at_least: a gateway that was never
  # measured must not read as "the router is clean, blame the ISP".
  if [ "$_icmp_filtered" -eq 0 ] && loss_below "$GW_LOSS" "$LOSS_WARN_PCT"; then
    if loss_at_least "$INET_LOSS" "$LOSS_CRIT_PCT" \
       && loss_at_least "$INET_LOSS_ALT" "$LOSS_CRIT_PCT"; then
      add_diag critical L1 "Your internet connection is dropping a large share of the traffic you send over it — ${INET_LOSS}% to ${INET_TARGET} and ${INET_LOSS_ALT}% to ${INET_TARGET_ALT} — while your own router is answering cleanly. Expect pages that hang half-loaded, video calls that freeze and drop, and downloads that crawl or stall. Because the router is fine and both independent test targets agree, the fault is past your front door: the line into your home, the modem, or your ISP. Reboot the modem once; if it comes back, report the loss figures to your ISP — that is the number that gets an engineer sent out."
    elif loss_at_least "$INET_LOSS" "$LOSS_WARN_PCT" \
         || loss_at_least "$INET_LOSS_ALT" "$LOSS_WARN_PCT"; then
      add_diag warn L2 "Your connection is losing some traffic on the way to the internet (${INET_LOSS:-?}% to ${INET_TARGET}, ${INET_LOSS_ALT:-?}% to ${INET_TARGET_ALT}) even though your router itself is clean. You'll notice it as calls that glitch for a second, pages that occasionally stall before loading, and stuttering video. It is not bad enough to break the connection, and it may come and go with the time of day if your ISP's local segment is congested. Worth re-running netdiag when it feels worst, and worth reporting if it persists."
    fi
  fi

  # WS-1 — congested WiFi channel.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt "$THRESH_WIFI_CHANNEL_NEIGHBOURS" ]; then
    add_diag warn WS-1 "Your WiFi channel (${WIFI_SCAN_CURRENT_CHANNEL}) is shared with ${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} neighbouring networks — they all interfere with each other. Switch to a less-crowded channel in your router's WiFi settings (good 5 GHz choices most routers don't pick automatically: 149, 153, 157, 161)."
  fi

  # WD-1 — WiFi flapping.
  if [ "$IS_WIFI" -eq 1 ] && [ "$WIFI_DISCONNECT_COUNT" -gt "$THRESH_WIFI_DISCONNECTS" ]; then
    add_diag warn WD-1 "Your WiFi keeps dropping and reconnecting (${WIFI_DISCONNECT_COUNT} times in the past hour). Common causes: weak signal at your desk, your Mac bouncing between two routers / mesh nodes that overlap, or a router firmware bug. If you have multiple WiFi points, check whether they're set up as a proper mesh."
  fi

  # NT-1 — system clock significantly off. Sub-second drift is round-trip
  # noise and not worth reporting; > 30 s breaks TLS everywhere; the
  # 1-30 s band is a soft warning since some apps tolerate it and some don't.
  if [ -n "$NTP_DRIFT_S" ] && awk -v d="$NTP_DRIFT_S" -v t="$THRESH_NTP_DRIFT_CRIT_S" 'BEGIN{exit !((d<0?-d:d) > t)}'; then
    add_diag critical NT-1 "Your Mac's clock is off by ${NTP_DRIFT_S} seconds — every secure website (anything starting with https://) will refuse to connect because clock-based certificate checks will fail. Fix: open System Settings → General → Date & Time and turn \"Set date and time automatically\" on."
  elif [ -n "$NTP_DRIFT_S" ] && awk -v d="$NTP_DRIFT_S" -v t="$THRESH_NTP_DRIFT_WARN_S" 'BEGIN{exit !((d<0?-d:d) > t)}'; then
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
  if [ -n "$DHCP_TIME_REMAINING_S" ] && [ "$DHCP_TIME_REMAINING_S" -gt 0 ] && [ "$DHCP_TIME_REMAINING_S" -lt "$THRESH_DHCP_LEASE_WARN_S" ]; then
    add_diag warn DH-1 "Your Mac's network-address lease from the router expires in $((DHCP_TIME_REMAINING_S / 60)) minutes. Normally it renews automatically, but if your router is rebooting or out of addresses at that moment, you'll suddenly lose the network with no warning. Keep an eye out."
  fi

  # DH-2 — DHCP vs system DNS mismatch. The comparison is deliberately
  # narrow: see dns_is_manual_override in lib/common.sh for why matching
  # only nameserver[0], and matching it as a substring, accused users of an
  # override they hadn't made on any network with IPv6 router adverts.
  if dns_is_manual_override "$DHCP_DNS_SERVERS" "$SYS_RES_ALL"; then
    add_diag info DH-2 "Your router suggested $DHCP_DNS_SERVERS for name lookups, but your Mac is using $(dns_routable_resolvers "$SYS_RES_ALL") instead — somebody manually overrode it. Fine if you did it on purpose (1.1.1.1 and 8.8.8.8 are common choices); surprising if you didn't."
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
