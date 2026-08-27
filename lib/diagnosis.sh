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

  # N1 / N1c — no usable network. Every rule below keys off a measurement
  # that only exists once there IS a link, so without this the most basic
  # failure mode (WiFi off, cable unplugged) fired zero rules and the run
  # ended with "Nothing obviously wrong — your network looks healthy" and
  # exit 0, on a machine with no network whatsoever.
  #
  # The split exists because those two sentences describe opposite
  # situations and N1 used to say the first one in both. "No default
  # route" was read as "nothing is connected", so a Mac sitting on a hotel
  # network at a strong signal with a valid DHCP lease was told it "isn't
  # joined to a WiFi network and has no working ethernet link" — while the
  # same report, three lines higher, printed the SSID and the signal
  # strength. LINK_UP (lib/linkstate.sh) is what tells them apart.
  #
  # N1c leads with the sign-in page rather than listing causes evenly,
  # because among networks that hand out an address and withhold a route
  # the portal is far and away the most common, and it is the only cause
  # with an action the user can take right now. The other causes follow in
  # the same sentence — the rule states what was observed, then what to
  # try, and never claims a portal was detected. CP-1 below is the rule
  # that gets to make that claim, and only when the probe confirms it.
  if [ -z "$GATEWAY" ] && [ "${LINK_UP:-0}" -eq 1 ]; then
    local _where _router_hint
    if [ "${IS_WIFI:-0}" -eq 1 ] && [ -n "${WIFI_SSID:-}" ] && [ "$WIFI_SSID" != "<redacted>" ]; then
      _where="You're connected to the WiFi network \"$WIFI_SSID\""
    elif [ "${IS_WIFI:-0}" -eq 1 ]; then
      _where="You're connected to WiFi"
    else
      _where="Your ethernet cable is connected"
    fi
    _router_hint="ask the network's owner"
    [ -n "${LINK_DHCP_ROUTER:-}" ] && _router_hint="try http://${LINK_DHCP_ROUTER} in a browser"
    add_diag critical N1c "$_where and it gave your Mac an address, but no way out to the internet. Networks in hotels, airports, cafés and offices usually do this until you open a browser and pass their sign-in or terms page — so start there: $_router_hint. If there's no sign-in page, the network handed out an address without a working route, and only its owner can fix that."
  elif [ -z "$GATEWAY" ] && [ "${LINK_SELF_ASSIGNED:-0}" -eq 1 ]; then
    # DH-3 — joined, but nothing answered the request for an address, so
    # macOS made one up. It sits between N1c and N1 and is a third thing
    # from both: N1c has a real lease and no route, N1 has no link at all,
    # and this has a link and no lease.
    #
    # Before LINK_SELF_ASSIGNED existed this fell through to N1 and told
    # the user their Mac "has no network connection at all — nothing is
    # joined", on a machine that is associated at full signal. The cause
    # and the fix are both entirely different, so the wrong rule here
    # sends the user to check a cable that is fine.
    local _joined _fix
    if [ "${IS_WIFI:-0}" -eq 1 ] && [ -n "${WIFI_SSID:-}" ] && [ "$WIFI_SSID" != "<redacted>" ]; then
      _joined="Your Mac is connected to the WiFi network \"$WIFI_SSID\""
      _fix="Turning WiFi off and on again, or forgetting and rejoining the network, makes your Mac ask again"
    elif [ "${IS_WIFI:-0}" -eq 1 ]; then
      _joined="Your Mac is connected to WiFi"
      _fix="Turning WiFi off and on again makes your Mac ask for an address again"
    else
      _joined="Your ethernet cable is carrying a link"
      _fix="Unplugging and replugging the cable makes your Mac ask for an address again"
    fi
    add_diag critical DH-3 "$_joined, but the network never gave it an address — so your Mac assigned itself a placeholder one (${LINK_IP:-a self-assigned address}) that can't reach anything. This is almost always the router's address service (DHCP) being down, out of addresses, or still starting up after a reboot. $_fix; if that doesn't work, restart the router. Nothing will work until the network hands out a real address."
  elif [ -z "$GATEWAY" ]; then
    add_diag critical N1 "Your Mac has no network connection at all — nothing is joined and no cable is carrying a link. Turn WiFi on and pick a network, or check that the ethernet cable is seated at both ends. Nothing else can be diagnosed until this is fixed."
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

  # W1/W2/WS-1 — WiFi conditions that are worth reporting even when they
  # have not yet caused packet loss. These rules used to be documented and
  # catalogued but never emitted, so a weak signal or crowded channel could
  # appear in the measurements with no actionable diagnosis.
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] \
     && is_numeric "$WIFI_RSSI" \
     && [ "$WIFI_RSSI" -lt "$THRESH_WIFI_RSSI_WEAK_DBM" ]; then
    add_diag warn W1 "Your WiFi signal is weak (${WIFI_RSSI} dBm), which can cause retransmissions, latency spikes, and dropouts. Move closer to the router, switch to a nearer access point, or try the other WiFi band."
  fi
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_SNR" ] \
     && is_numeric "$WIFI_SNR" \
     && [ "$WIFI_SNR" -lt "$THRESH_WIFI_SNR_LOW_DB" ]; then
    add_diag warn W2 "Your WiFi signal is being overwhelmed by interference (SNR ${WIFI_SNR} dB). Try a less crowded channel or move the router away from sources of radio interference."
  fi
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" ] \
     && is_numeric "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" \
     && [ "$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" -gt "$THRESH_WIFI_CHANNEL_NEIGHBOURS" ]; then
    add_diag warn WS-1 "Your WiFi channel is crowded (${WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS} neighbouring networks). If performance is inconsistent, choose a less busy channel or let the router select one automatically."
  fi

  # TCP-1 — TCP works, ICMP is filtered. Decided before G1/G2/G3 because it
  # decides whether they fire at all, and mirrored exactly in
  # lib/monitor.sh's _mon_rules (tests/test_monitor.bats holds the two to
  # the same rule set for the same link).
  #
  # Both used to fire together, which put "reboot the router (unplug it for
  # 30 seconds)" and "the network is up; don't worry about the ping numbers
  # above" in one report, let the critical one own the headline, and exited
  # 2 on every hotel and corporate network. TCP reaching 1.1.1.1:443 means
  # packets are crossing the gateway, so the gateway is forwarding and
  # merely declining to answer pings itself — and THRESH_ICMP_FILTERED_LOSS_PCT
  # is deliberately set well above LOSS_CRIT_PCT so that inference is safe.
  # No figure is lost: TCP-1's own prose quotes the gateway loss.
  local _gw_icmp_filtered=0
  if [ "$TCP_REACH_ANY_OK" -eq 1 ] && loss_at_least "$GW_LOSS" "$THRESH_ICMP_FILTERED_LOSS_PCT"; then
    _gw_icmp_filtered=1
    add_diag info TCP-1 "Actual connections work fine, only the \"ping\" tests fail (${GW_LOSS}% loss to the gateway) — something on the path is blocking pings but not real traffic. Common on hotel WiFi, corporate networks, and some ISPs. The network is up; don't worry about the ping numbers above."
  fi

  # ETH-1 / ETH-2 — the wired link negotiated badly. Decided *before*
  # G1/G2/G3 because a half-duplex link is a cause of gateway loss, and
  # G2's headline advice ("reboot the router") is wrong when it is: the
  # box is fine and the negotiation is not.
  #
  # Both compare two measured values rather than testing a cutoff, so
  # neither needs a threshold: "100 Mb/s" is only a fault relative to a
  # port that can do more, and half duplex is only a fault on a port that
  # advertises full. On a genuinely 100 Mb/s half-duplex-only adapter both
  # stay quiet, because there both numbers are simply the truth.
  local _eth_half=0
  if [ -n "${LINK_MEDIA_MBPS:-}" ] && is_numeric "${LINK_MEDIA_MBPS:-}"; then
    if [ "${LINK_DUPLEX:-}" = "half" ] \
       && [ "${LINK_MEDIA_FULL_DUPLEX_CAPABLE:-0}" -eq 1 ]; then
      _eth_half=1
      add_diag critical ETH-2 "Your ethernet connection has settled on half-duplex — it can only send or receive at any one moment, not both — even though this port supports doing both at once. That causes collisions and heavy packet loss, and it looks exactly like a failing router. It's a failed negotiation, usually because one end (a switch port, or the Mac's own settings) is pinned to a fixed speed instead of automatic. Set both ends back to automatic, and swap the cable if that doesn't take."
    fi
    if [ -n "${LINK_MEDIA_MAX_MBPS:-}" ] && is_numeric "${LINK_MEDIA_MAX_MBPS:-}" \
       && [ "$LINK_MEDIA_MBPS" -lt "$LINK_MEDIA_MAX_MBPS" ]; then
      add_diag warn ETH-1 "Your ethernet connection negotiated ${LINK_MEDIA_MBPS} Mb/s, but this port can do ${LINK_MEDIA_MAX_MBPS} Mb/s — so something is holding the link below what it's capable of, and no speed test can exceed that ceiling no matter how fast your internet plan is. A damaged or low-grade cable is the usual cause (a broken pair drops a gigabit link to a hundred), followed by a cheap dock or hub in the path. Try a different cable, and plug straight into the router if you can."
    fi
  fi

  # G1/G2/G3 — gateway loss. All three describe trouble on the connection
  # between the Mac and the router *inside the home* — never the ISP or the
  # wider internet — and say so in plain words, because a reader who
  # doesn't know the difference between "router" and "internet" reads any
  # mention of packet loss as "my internet is down". Each names the most
  # likely cause too: Wi-Fi signal/interference, or on ethernet, the
  # cable/port — mirrored from the same branch G3 uses below.
  if [ "$_gw_icmp_filtered" -eq 1 ]; then
    : # TCP-1 has already described this link.
  elif loss_at_least "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ -n "$WIFI_RSSI" ] && is_numeric "$WIFI_RSSI" && [ "$WIFI_RSSI" -le "$THRESH_WIFI_RSSI_G1_DBM" ]; then
      add_diag critical G1 "Your Mac is losing ${GW_LOSS}% of the packets it sends to your router — the box that gives you internet in your home — not out on the wider internet. Your Wi-Fi signal here is weak (${WIFI_RSSI} dBm), which is almost certainly the cause. Try moving closer to the router, or switching to a closer access point if you have one."
    elif [ "$_eth_half" -eq 1 ]; then
      # ETH-2 already named the cause. Repeating "reboot the router" here
      # would send the user to power-cycle a box that is working, so this
      # branch states the loss and points at the diagnosis that explains
      # it rather than offering a second, contradictory fix.
      add_diag critical G2 "Your Mac is losing ${GW_LOSS}% of the packets it sends to your router — the box that gives you internet in your home — not out on the wider internet or with your provider. That is what the half-duplex ethernet link above causes, so fix the negotiation first rather than the router; collisions on a half-duplex link produce exactly this."
    else
      add_diag critical G2 "Your Mac is losing ${GW_LOSS}% of the packets it sends to your router — the box that gives you internet in your home — not out on the wider internet or with your provider. Try rebooting the router (unplug it for 30 seconds, then plug it back in) or moving closer to it; on ethernet, check the cable."
    fi
  elif loss_at_least "$GW_LOSS" "$LOSS_WARN_PCT"; then
    # G3 — the band under G1's critical floor. The cause sentence branches
    # exactly like G1/G2 above: a weak signal (or, where it was actually
    # measured, a low SNR) is blamed on the signal; a good signal still
    # points at Wi-Fi interference, the most common cause at this level;
    # ethernet points at the cable or the switch port.
    local _g3_cause
    if [ "$IS_WIFI" -eq 1 ] \
       && { { [ -n "$WIFI_RSSI" ] && is_numeric "$WIFI_RSSI" && [ "$WIFI_RSSI" -le "$THRESH_WIFI_RSSI_WEAK_DBM" ]; } \
         || { [ -n "$WIFI_SNR" ]  && is_numeric "$WIFI_SNR"  && [ "$WIFI_SNR" -lt "$THRESH_WIFI_SNR_LOW_DB" ]; }; }; then
      _g3_cause="Your Wi-Fi signal here is weak, which is the likely cause — try moving closer to the router, or switching to a less crowded band or channel."
    elif [ "$IS_WIFI" -eq 1 ]; then
      _g3_cause="Even with a good signal, Wi-Fi interference — from microwaves, neighboring networks, or distance — is the most common cause at this level; restarting the router can help if it keeps happening."
    elif [ "$_eth_half" -eq 1 ]; then
      _g3_cause="The half-duplex ethernet link above is the likely cause — collisions on a half-duplex link produce exactly this — so fix the negotiation before suspecting anything else."
    else
      _g3_cause="On ethernet this usually points to the cable or the port — try reseating or swapping the cable."
    fi
    add_diag warn G3 "Your Mac is losing about ${GW_LOSS}% of the packets it sends to your router — the box that gives you internet in your home — not to the wider internet, so your internet service itself looks fine from here. It's not enough to break the connection outright, but pages can stall for a second and calls can break up. $_g3_cause"
  fi

  # CP-1 — a captive portal is intercepting this network. Two literal
  # call sites rather than one with a variable severity: every add_diag
  # site in this tree passes its severity as a literal token, and
  # tests/test_rules_catalog.bats extracts them by regex to prove the
  # catalog matches the code.
  #
  # This rule existed for months with no scan call site at all. It lived
  # only in lib/monitor.sh, and docs/DIAGNOSIS-RULES.md argued a scan
  # didn't need one "because P1/P2 fire anyway". They do — and what they
  # say is "almost certainly an outage on your ISP's side, check their
  # status page or call support", which is exactly wrong on a hotel
  # network and sends the user to phone a company that is working fine.
  if [ "${CAPTIVE_PORTAL:-0}" -eq 1 ]; then
    if [ "$PUBLIC_OK" -eq 0 ]; then
      add_diag critical CP-1 "This network wants you to sign in before it will let you online — the check for internet access came back intercepted (HTTP ${CAPTIVE_PORTAL_CODE:-?}) rather than answered. Open a browser and load any plain http:// address; the network's sign-in or terms page should appear. Nothing else will work until you accept it. There is nothing wrong with your Mac, your router, or your internet provider."
    else
      add_diag warn CP-1 "This network is intercepting web requests to show a sign-in or terms page (HTTP ${CAPTIVE_PORTAL_CODE:-?}), even though traffic is currently getting through. Expect connections to break when its session expires — open a browser and complete the page to be safe."
    fi
  fi

  # P1/P2 — public unreachable. The gateway guard was `== 0` exactly until
  # G3 landed, which left a hole: an outage measured alongside 8% gateway
  # loss matched neither P1/P2 (loss was not 0) nor G1/G2 (loss was under
  # 20), so a total loss of internet produced no diagnosis at all. The
  # guard now means "the router is not the problem", not "the router is
  # flawless".
  #
  # CP-1 above owns the portal case. Without this guard both fire, and P1's
  # "call your ISP" outranks the one instruction that actually works.
  if [ "$PUBLIC_OK" -eq 0 ] && [ "${CAPTIVE_PORTAL:-0}" -eq 0 ] \
     && loss_below "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ "$DNS_OK" -eq 0 ]; then
      add_diag critical P1 "Your local network is working but the wider internet is unreachable, and name lookups are also failing — likely a DNS or upstream-ISP outage. Try opening http://1.1.1.1 in a browser: if it loads, the problem is DNS; if not, it's the ISP."
    else
      add_diag critical P2 "Your local network is healthy and name lookups work, but no public website responds — almost certainly an outage on your ISP's side. Check their status page or call support."
    fi
  fi

  # D1 / D2 — name resolution is failing. DNS_LINES proves the check ran;
  # without it a skipped-DNS run would accuse a healthy resolver.
  #
  # D1 is the partial case and requires the internet to be up, because its
  # whole content is "everything else works, so it's your resolver". D2 is
  # the total case and requires nothing of the sort — which is the point.
  # With only D1, a network whose internet was down measured "0 of 6
  # resolvers OK" and fired no dns-category rule at all, and the GUI,
  # which colors the DNS row from the rules the CLI hands it, rendered a
  # green dot beside the words "0 of 6 resolvers OK". A row cannot be
  # allowed to contradict its own value; the fix belongs here rather than
  # in Swift because the GUI holds no diagnostic logic by design.
  #
  # Ordered D2-then-D1 with the elif so the two can never both fire.
  if [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 0 ]; then
    add_diag warn D2 "No name lookups are working at all — every DNS server your Mac tried failed to answer. On its own that would point at your DNS settings, but nothing else on the internet is reachable either, so this is most likely a symptom rather than the cause. Fix the connection first; if lookups still fail once it's back, switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS."
  elif [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then
    add_diag warn D1 "The internet works but some name lookups are failing — your DNS server is flaky. Switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS."
  fi

  # D3 — slow DNS resolver (> 250 ms)
  if [ -n "$SYS_RES_MS" ] && is_numeric "$SYS_RES_MS" && [ "$SYS_RES_MS" -gt "$THRESH_DNS_LATENCY_WARN_MS" ] && [ "${DNS_OK:-0}" -eq 1 ]; then
    add_diag warn D3 "Your DNS server ($SYS_RES) is very slow to respond (${SYS_RES_MS} ms) — every new website or link you click will pause before opening. Switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS for noticeably snappier browsing."
  fi

  # D4 — DNS hijacking / search redirection
  if [ -n "${DNS_NXDOMAIN_HIJACK_IP:-}" ]; then
    add_diag warn D4 "Your internet provider is intercepting mistyped website addresses and redirecting them to a search/advertising page ($DNS_NXDOMAIN_HIJACK_IP) instead of returning an error. Switch your DNS to 1.1.1.1 or 8.8.8.8 or turn on Encrypted DNS (DNS-over-HTTPS) to prevent ISP tracking."
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

  # V6-2 — unresponsive IPv6 DNS resolver causing fallback stalls
  if [ -n "${IPV6_DNS_FAIL:-}" ] && [ "${DNS_OK:-0}" -eq 1 ]; then
    add_diag warn V6-2 "Your router gave your Mac an IPv6 DNS server ($IPV6_DNS_FAIL), but it isn't responding. Every website you visit pauses for 2 to 3 seconds while your Mac waits for IPv6 to time out before falling back to IPv4. Fix: Update your router's IPv6 settings or disable IPv6 in System Settings → Network."
  fi

  # VPN-1 — a VPN is carrying the default route. info, never a fault: the
  # point is that every measurement below describes the tunnel rather than
  # the local link, so the user doesn't blame their router for the VPN.
  if [ "$VPN_ACTIVE" -eq 1 ]; then
    add_diag info VPN-1 "A VPN is carrying your traffic right now (${VPN_NAME:-$VPN_TYPE}). Everything measured above — router, latency, traceroute, speed — describes the tunnel and the VPN's exit server, not your own network. If something looks slow here, the VPN is as likely a cause as your ISP. Disconnect it and run netdiag again to see the underlying connection."
  fi

  # TCP-1 is decided above the gateway loss rules, because it decides
  # whether they fire at all.

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

  # DI-1 — incomplete gateway ARP. Duplicate IPs are DI-2, just below.
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
