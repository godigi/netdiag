#!/usr/bin/env python3
"""Emit `netdiag --rules-catalog` as a single JSON object.

Every rule the diagnosis engine (`lib/diagnosis.sh`, `lib/wan.sh`,
`lib/output.sh`) and the live monitor (`lib/monitor.sh::_mon_rules`) can
emit gets one entry here: a title, a category, a descriptive severity, a
scope, plain-English prose, and an anchor into
`docs/DIAGNOSIS-RULES.md`.

This exists because CLAUDE.md draws a hard line: "The GUI holds no
diagnostic logic. gui/ renders what the CLI decides: rule IDs come from
status.rules, prose comes from diagnosis[].summary verbatim." The GUI has
had nothing to show next to a rule-ID chip except the ID itself — this
catalog is the plain-English layer that belongs in the CLI instead of
being reinvented in Swift.

Two things this is emphatically not:
  * Not per-incident prose. `blurb` describes what a rule means in
    general — what it means, what usually causes it, what helps. The
    text a user reads about *this run's* fault is, and remains,
    `diagnosis[].summary`, generated fresh each run with this run's own
    numbers baked in. Reusing that text here would go stale the moment
    either drifts, so the wording below is adapted from —
    not copied from — docs/DIAGNOSIS-RULES.md's prose, and says nothing
    docs/DIAGNOSIS-RULES.md doesn't already say.
  * Not a judge. Nothing here reads lib/thresholds.sh and nothing here
    contains a numeric cutoff — blurbs stay qualitative ("weak signal",
    "drifted noticeably") and point at `doc` for the actual number. Same
    split JSON-SCHEMA.md draws everywhere else between a measurement and
    a verdict.

Called once from bin/netdiag's --rules-catalog mode with the running
version already resolved in bash and passed through
NETDIAG_RULES_VERSION — the same handshake shape capabilities.py uses for
NETDIAG_CAP_VERSION, kept as its own variable because this helper answers
a narrower question (what does each rule mean) than --capabilities does
(what can this install do).

── The metrics glossary ──────────────────────────────────────────────────
`metrics` is a second, sibling array on the same document: not one entry
per diagnosis rule but one entry per *jargon term* the report card shows —
"router", "MTU", "jitter" — explaining what the word means in plain
English, for the reader who has never heard it before. It lives here
rather than in a standalone `helpers/glossary.py` because it answers the
same question `rules` does ("what does this word on screen mean?") for the
same consumer (a `questionmark.circle` hint in `RunReportView`), and a
second CLI mode would just be a second round trip and a second cache file
for something this small. `SCHEMA_RULES_CATALOG` bumped 1 → 2 for the
addition — additive only, per this schema's own promise in
docs/JSON-SCHEMA.md, so a build that only reads `rules` keeps working
unchanged.

Like `blurb`, `help` stays qualitative: no dBm, no ms, no percent. A
number belongs in lib/thresholds.sh and nowhere else, and a glossary entry
answers "what is this thing" rather than "is this reading good".
"""

from __future__ import annotations

import json
import os
import sys

# This file's own schema: the shape of the --rules-catalog document.
# v1 → v2: added the sibling `metrics` glossary array.
SCHEMA_RULES_CATALOG = 2

# The measurement family each rule judges — the GUI tints a report-card
# row by this, not by severity, so a "varies"-severity rule like B1 still
# lands on one specific row.
CATEGORIES = frozenset({
    "router", "internet", "dns", "wifi", "load", "mtu", "speed", "clock",
    "ipv6", "vpn", "lan", "dhcp", "topology", "baseline",
})
# "speed" is used by zero rules today: it is reserved for ST-1 (speed
# regression), which docs/DIAGNOSIS-RULES.md lists but nothing emits yet.

# "varies" covers the handful of rules that grade by magnitude — the same
# add_diag call site chooses warn or critical depending on how far past
# the threshold the measurement landed (B1, B2, M1, NT-1 below). The
# per-incident severity always arrives in diagnosis[].severity anyway;
# this field is descriptive, not authoritative.
SEVERITIES = frozenset({"info", "warn", "critical", "varies"})

# scan    — lib/diagnosis.sh / lib/wan.sh / lib/output.sh only.
# monitor — lib/monitor.sh::_mon_rules only (CP-1: there is no scan-mode
#           reading of a captive portal for it to mirror).
# both    — evaluated in both places, on whichever inputs that mode has.
SCOPES = frozenset({"scan", "monitor", "both"})

# One entry per rule the engine can emit. Order follows
# docs/DIAGNOSIS-RULES.md's own reading order rather than rule-ID sort,
# except that a rule's variants sit beside it (N1b after N1, DI-2 after
# DI-1) even where the doc parted them — grouping siblings beats strict
# parity for a reader looking one rule up.
#
# UP-1 is deliberately absent: docs/DIAGNOSIS-RULES.md documents it as
# reserved (the Report card already shows UPnP state directly; no
# add_diag call exists anywhere for it) — see tests/test_rules_catalog.bats
# for the explicit exclusion this drives.
RULES: list[dict[str, str]] = [
    {
        "id": "N1",
        "title": "No network connection at all",
        "category": "router",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Nothing is joined: no WiFi network is associated and no "
            "ethernet cable is carrying a link. Nothing else can be "
            "diagnosed until basic connectivity exists. Turn WiFi on and "
            "pick a network, or check that the ethernet cable is seated "
            "at both ends."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1--no-network-at-all",
    },
    {
        "id": "N1b",
        "title": "Internet unreachable (focused run)",
        "category": "internet",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "A focused run (like an MTU-only check) skips the full gateway "
            "test, so this rule catches an outage that would otherwise "
            "slip through unreported: your Mac has a router, but nothing "
            "on the public internet answered. Re-run a full scan to find "
            "out whether the problem is the router, the ISP, or DNS."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1b--router-present-nothing-public-responds",
    },
    {
        "id": "N1c",
        "title": "Joined to a network with no route out",
        "category": "router",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac is associated and holds an address from this "
            "network, but the network has given it no route to the "
            "internet. Hotel, airport, café and office WiFi usually "
            "withhold one until you open a browser and pass a sign-in or "
            "terms page. Failing that, the network handed out an address "
            "without a working route, which only its owner can fix."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1c--joined-with-no-route-out",
    },
    {
        "id": "W1",
        "title": "Weak WiFi signal",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your wireless signal is weak enough to cause retransmissions, "
            "latency spikes, and dropouts. Moving closer to the router or "
            "switching to a nearer access point or band usually helps."
        ),
        "doc": "DIAGNOSIS-RULES.md#w1--weak-wifi-signal",
    },
    {
        "id": "W2",
        "title": "Low WiFi signal-to-noise ratio",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Interference is competing with your wireless signal. A less "
            "crowded channel or moving the router away from other radio "
            "sources can improve it."
        ),
        "doc": "DIAGNOSIS-RULES.md#w2--low-wifi-snr",
    },
    {
        "id": "WS-1",
        "title": "WiFi channel is congested",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Several neighbouring networks share your current channel. "
            "That contention can make an otherwise strong connection "
            "inconsistent; a less busy channel may help."
        ),
        "doc": "DIAGNOSIS-RULES.md#ws-1--wifi-channel-is-congested",
    },
    {
        "id": "G1",
        "title": "Gateway packet loss with weak Wi-Fi",
        "category": "wifi",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your Mac is losing packets to your router while your Wi-Fi "
            "signal is weak. The wireless link is the problem, not your "
            "router hardware or your internet provider. Moving closer to "
            "the router or switching to a closer access point clears this."
        ),
        "doc": "DIAGNOSIS-RULES.md#g1--gateway-loss--weak-wifi",
    },
    {
        "id": "G2",
        "title": "Router dropping packets",
        "category": "router",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your Mac is losing packets between your Mac and your router "
            "— the connection between your Mac and your router is "
            "severely degraded. A reboot of the router (power off, wait, "
            "then power back on) or moving closer to it clears this in "
            "most cases. On ethernet, check the cable."
        ),
        "doc": "DIAGNOSIS-RULES.md#g2--gateway-loss-with-healthy-wifi",
    },
    {
        "id": "G3",
        "title": "Minor packet loss to router",
        "category": "router",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "A smaller share of packets to your router — the box that "
            "gives you internet in your home — are going missing. This is "
            "not your internet provider; your internet service itself "
            "looks fine from here. Not enough to break the connection "
            "outright, but enough that pages stall and calls occasionally "
            "break up. On WiFi this is usually signal or interference; on "
            "ethernet, suspect the cable or the switch port."
        ),
        "doc": "DIAGNOSIS-RULES.md#g3--gateway-loss-below-the-critical-floor",
    },
    {
        "id": "P1",
        "title": "DNS and internet both down",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your local network works, but neither the wider internet nor "
            "name lookups are responding — most likely a DNS or "
            "upstream ISP outage. Try loading a raw address like "
            "http://1.1.1.1: if that works, DNS is the culprit; if not, "
            "it's the ISP."
        ),
        "doc": "DIAGNOSIS-RULES.md#p1--dns-down-public-unreachable",
    },
    {
        "id": "P2",
        "title": "Internet unreachable, DNS fine",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your local network is healthy and DNS is resolving names "
            "fine, but no public site responds — this almost always "
            "means an outage on your ISP's side. Check their status page "
            "or contact support."
        ),
        "doc": "DIAGNOSIS-RULES.md#p2--public-unreachable-dns-up",
    },
    {
        "id": "L1",
        "title": "Severe internet packet loss",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "A large share of the traffic sent out to the internet is "
            "being dropped, while the router itself answers cleanly — "
            "so the fault sits past your front door, on the line, the "
            "modem, or with the ISP. Expect pages that hang, calls that "
            "freeze, and downloads that stall; a modem reboot is worth "
            "trying before reporting the numbers to your ISP."
        ),
        "doc": "DIAGNOSIS-RULES.md#l1--severe-internet-side-packet-loss",
    },
    {
        "id": "L2",
        "title": "Moderate internet packet loss",
        "category": "internet",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "Some traffic is being lost on the way out to the internet "
            "even though the router itself is clean — enough to cause "
            "an occasional stutter or stall, but not enough to break the "
            "connection outright. It's often tied to time-of-day "
            "congestion on the ISP's local segment, so it's worth "
            "re-running when it feels worst."
        ),
        "doc": "DIAGNOSIS-RULES.md#l2--moderate-internet-side-packet-loss",
    },
    {
        "id": "ICMP-1",
        "title": "Ping blocked, connection fine",
        "category": "internet",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "Ping to the outside world fails completely, but real traffic "
            "— web pages, DNS, TCP connections — all work fine, "
            "so this isn't an outage. Some ISPs and most corporate or "
            "hotel networks block ping specifically while letting "
            "everything else through; the latency numbers just can't be "
            "measured here."
        ),
        "doc": "DIAGNOSIS-RULES.md#icmp-1--ping-filtered-upstream-real-traffic-fine",
    },
    {
        "id": "D1",
        "title": "DNS resolver flaky",
        "category": "dns",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "The internet itself is reachable, but some name lookups are "
            "failing, which points at a flaky DNS resolver. Switching to "
            "a public resolver such as Cloudflare's or Google's in your "
            "network settings usually clears it up."
        ),
        "doc": "DIAGNOSIS-RULES.md#d1--partial-dns-internet-reachable",
    },
    {
        "id": "D2",
        "title": "No name lookups working at all",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Every DNS server your Mac tried failed to answer, and the "
            "wider internet is unreachable too — so this is most likely a "
            "symptom of the connection being down rather than a DNS fault "
            "in its own right. Fix the connection first. If lookups still "
            "fail once it is back, switch your DNS to Cloudflare or "
            "Google in System Settings."
        ),
        "doc": "DIAGNOSIS-RULES.md#d2--no-name-lookups-working-at-all",
    },
    {
        "id": "D3",
        "title": "DNS server sluggish",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your configured DNS server takes a long time to answer "
            "name lookups, so every new website or link you click pauses "
            "before it begins loading. Switching to a fast public resolver "
            "like Cloudflare's or Google's in your network settings clears "
            "the delay."
        ),
        "doc": "DIAGNOSIS-RULES.md#d3--slow-dns-resolver-latency",
    },
    {
        "id": "D4",
        "title": "DNS searches intercepted",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your DNS server intercepts mistyped website addresses and "
            "redirects them to an advertising or search portal rather than "
            "reporting that the address does not exist. Switching to a "
            "standard public resolver or enabling Encrypted DNS stops "
            "the redirection."
        ),
        "doc": "DIAGNOSIS-RULES.md#d4--dns-hijacking-and-search-redirection",
    },
    {
        "id": "B1",
        "title": "Bufferbloat at the router",
        "category": "load",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your router gets sluggish whenever something is downloading "
            "or uploading heavily, adding noticeable extra delay that "
            "makes calls and games feel laggy or worse. Enabling Smart "
            "Queue Management (SQM) or QoS in the router's admin page "
            "— or replacing it with one that supports it — fixes "
            "the underlying queueing problem."
        ),
        "doc": "DIAGNOSIS-RULES.md#b1--bufferbloat-at-gateway-hop",
    },
    {
        "id": "B2",
        "title": "Bufferbloat at the ISP",
        "category": "load",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "The slowdown under heavy use traces to your ISP's own "
            "equipment rather than your router, adding extra delay under "
            "load that can hurt calls and games. A modem firmware update "
            "can help if you control it; otherwise it's the ISP's "
            "responsibility to fix."
        ),
        "doc": "DIAGNOSIS-RULES.md#b2--bufferbloat-at-isp-hop-only",
    },
    {
        "id": "M1",
        "title": "Path MTU too small",
        "category": "mtu",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your network is silently dropping packets above a certain "
            "size, so some websites hang while others load fine — a "
            "classic symptom of an unconfigured VPN, PPPoE, or tunnelled "
            "link. Disconnecting any VPN often clears it; otherwise check "
            "the router's WAN MTU or MSS-clamping setting."
        ),
        "doc": "DIAGNOSIS-RULES.md#m1--path-mtu-below-1500",
    },
    {
        "id": "MT1",
        "title": "First lossy hop found",
        "category": "internet",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "One specific hop on the way to the internet is where packet "
            "loss actually starts; hops after it usually just inherit the "
            "problem rather than adding their own. Whoever owns that hop "
            "— your router, your ISP, or a transit network further "
            "along — is the one to investigate."
        ),
        "doc": "DIAGNOSIS-RULES.md#mt1--first-lossy-hop-identified",
    },
    {
        "id": "V6-1",
        "title": "IPv6 partially broken",
        "category": "ipv6",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your network has a half-working IPv6 setup: big sites feel "
            "sluggish for the first moment of every page load because "
            "your Mac tries the modern path first, waits for it to fail, "
            "then falls back to the old one. Rebooting the router often "
            "fixes it; if it persists, ask your ISP whether IPv6 is "
            "actually provisioned."
        ),
        "doc": "DIAGNOSIS-RULES.md#v6-1--ipv6-broken-while-ipv4-works",
    },
    {
        "id": "V6-2",
        "title": "IPv6 DNS resolver unresponsive",
        "category": "ipv6",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your router provided an IPv6 DNS server address that is not "
            "responding. Websites pause for several seconds before opening "
            "while your Mac waits for the IPv6 lookup to time out before "
            "falling back to IPv4."
        ),
        "doc": "DIAGNOSIS-RULES.md#v6-2--unresponsive-ipv6-dns-resolver",
    },
    {
        "id": "VPN-1",
        "title": "VPN carrying your traffic",
        "category": "vpn",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "A VPN is currently carrying your traffic, so everything else "
            "measured in the report — the \"router,\" latency, "
            "traceroute, speed — actually describes the tunnel and "
            "its exit server, not your real network. If something looks "
            "slow, the VPN is as likely a cause as your ISP; disconnect "
            "it and run again for a picture of the underlying connection."
        ),
        "doc": "DIAGNOSIS-RULES.md#vpn-1--vpn-is-carrying-the-default-route",
    },
    {
        "id": "TCP-1",
        "title": "ICMP blocked, TCP fine",
        "category": "router",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "Real connections work fine — only the ping-style tests "
            "are failing, because something on the path is blocking ICMP "
            "specifically while letting actual traffic through. Common on "
            "hotel WiFi, corporate networks, and some ISPs; the network "
            "is up, and the ping-based loss this check reports can be "
            "ignored."
        ),
        "doc": "DIAGNOSIS-RULES.md#tcp-1--tcp-works-icmp-is-filtered",
    },

    {
        "id": "WD-1",
        "title": "WiFi flapping / roaming",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your WiFi keeps dropping and reconnecting more than "
            "expected. Common causes are weak signal at your desk, a Mac "
            "bouncing between two overlapping access points, or a router "
            "firmware bug — worth checking whether multiple access "
            "points are actually set up as a proper mesh."
        ),
        "doc": "DIAGNOSIS-RULES.md#wd-1--wifi-link-is-flapping",
    },
    {
        "id": "WI-1",
        "title": "macOS is withholding the network's name",
        "category": "wifi",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "macOS isn't telling netdiag which WiFi network you're on, "
            "so this run is filed under a generic name instead of the "
            "real one. Nothing is broken, but history for this network "
            "gets mixed in with every other unnamed network, making "
            "per-network comparisons and baselines less useful. "
            "Granting Location Services to your terminal fixes it for "
            "future runs."
        ),
        "doc": "DIAGNOSIS-RULES.md#wi-1--macos-is-withholding-the-networks-name",
    },
    {
        "id": "SP-1",
        "title": "WiFi is the speed cap, not your plan",
        "category": "speed",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your download speed is about as fast as this WiFi "
            "connection can physically carry, so the measured number is "
            "the ceiling of your wireless link rather than of your "
            "internet plan — a faster plan would not change it. Plug in "
            "with an ethernet cable, or move closer to the router and "
            "prefer the higher-frequency band, to see what the "
            "connection can really do."
        ),
        "doc": "DIAGNOSIS-RULES.md#sp-1--the-wireless-link-is-the-speed-cap",
    },
    {
        "id": "MET-1",
        "title": "Metered connection — data costs money here",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "You're online through a phone or tethered device, so data "
            "here comes out of a cellular allowance. Everything else in "
            "this report describes that mobile connection rather than a "
            "home network, so advice about routers and cables does not "
            "apply — and the speed test is skipped by default, because "
            "it would spend a large part of your allowance. Pass "
            "--speed to run it anyway."
        ),
        "doc": "DIAGNOSIS-RULES.md#met-1--metered-connection",
    },
    {
        "id": "NT-1",
        "title": "System clock drifted",
        "category": "clock",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your Mac's clock has drifted noticeably from real time, and "
            "since secure websites validate certificates against the "
            "system clock, that starts breaking HTTPS connections. "
            "Turning on \"Set date and time automatically\" in System "
            "Settings usually fixes it."
        ),
        "doc": "DIAGNOSIS-RULES.md#nt-1--system-clock-drift--30-s",
    },
    {
        "id": "DI-1",
        "title": "Router unreachable at layer 2",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac can't resolve your router at the hardware (ARP) "
            "layer at all — the connection between them is broken below "
            "IP, so nothing else in this report matters until it's "
            "fixed. Usually a loose cable, a WiFi link that's actually "
            "down, or a bad switch port; check the physical connection "
            "first."
        ),
        "doc": "DIAGNOSIS-RULES.md#di-1--router-unreachable-at-the-hardware-arp-layer",
    },
    {
        "id": "DI-2",
        "title": "Duplicate IP on the LAN",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Two devices on your network are using the same IP address "
            "and will intermittently steal each other's traffic. This is "
            "usually a manually-set static IP colliding with the "
            "router's DHCP pool, or a second DHCP server on the network "
            "— find and renumber one of the offending devices."
        ),
        "doc": "DIAGNOSIS-RULES.md#di-2--duplicate-ip-on-the-lan",
    },
    {
        "id": "ETH-1",
        "title": "Ethernet link slower than the port allows",
        "category": "lan",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your ethernet connection negotiated a slower speed than the "
            "port is capable of, so no speed test can exceed that "
            "ceiling however fast your internet plan is. A damaged or "
            "low-grade cable is the usual cause — a broken pair drops a "
            "gigabit link to a hundred — followed by a cheap dock or hub "
            "in the path. Try a different cable, and plug straight into "
            "the router if you can."
        ),
        "doc": "DIAGNOSIS-RULES.md#eth-1--ethernet-negotiated-below-the-ports-capability",
    },
    {
        "id": "ETH-2",
        "title": "Ethernet link stuck on half duplex",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your ethernet connection can only send or receive at any "
            "one moment, not both, even though the port supports doing "
            "both at once. That causes collisions and heavy packet loss "
            "and looks exactly like a failing router. It is a failed "
            "negotiation, usually because one end is pinned to a fixed "
            "speed instead of automatic."
        ),
        "doc": "DIAGNOSIS-RULES.md#eth-2--ethernet-stuck-on-half-duplex",
    },
    {
        "id": "DH-1",
        "title": "DHCP lease expiring soon",
        "category": "dhcp",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your Mac's DHCP lease from the router is due to renew "
            "shortly. Renewal normally happens automatically, but if the "
            "router is rebooting or has run out of addresses at that "
            "moment, the network can drop without warning — worth "
            "keeping an eye on."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-1--dhcp-lease-expires-within-1-hour",
    },
    {
        "id": "DH-3",
        "title": "No address handed out — Mac assigned its own",
        "category": "dhcp",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac is joined to this network but the network never "
            "gave it an address, so it assigned itself a placeholder one "
            "that cannot reach anything. Usually the router's address "
            "service is down, out of addresses, or still starting up "
            "after a reboot. Rejoining the network makes your Mac ask "
            "again; failing that, restart the router."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-3--self-assigned-address-dhcp-never-answered",
    },
    {
        "id": "DH-2",
        "title": "DHCP DNS overridden",
        "category": "dhcp",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "The DNS servers your router handed out over DHCP don't "
            "match what your Mac is actually using — someone (or "
            "some app) manually overrode the resolver. Fine if that was "
            "intentional, such as pointing at a public resolver; worth a "
            "second look if it wasn't."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-2--dhcp-handed-dns-differs-from-system-resolver",
    },
    {
        "id": "WAN-1",
        "title": "Multiple ISPs load-balanced",
        "category": "topology",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Outgoing connections from your Mac are landing on more than "
            "one internet provider, which is usually an intentional "
            "multi-WAN router setup. It explains some odd symptoms, like "
            "a service complaining your IP keeps changing or an app "
            "behaving inconsistently between connections."
        ),
        "doc": "DIAGNOSIS-RULES.md#wan-1--outbound-traffic-load-balanced-across-multiple-isps",
    },
    {
        "id": "WAN-1b",
        "title": "CGNAT IP rotation",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "You're behind your ISP's shared-address pool: the same "
            "provider is handing your traffic different public IP "
            "addresses over time. Common on cellular and budget "
            "connections and not something you can fix locally, but it "
            "explains why a service might complain that your IP keeps "
            "changing."
        ),
        "doc": "DIAGNOSIS-RULES.md#wan-1b--same-isp-multiple-public-ips-cgnat-round-robin",
    },
    {
        "id": "NAT-1",
        "title": "Double-NAT chain",
        "category": "topology",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "More than one router in your home is chained together, each "
            "doing its own network address translation. That breaks "
            "anything that needs an incoming connection to reach a "
            "specific device — games, Plex, Steam in-home streaming, "
            "video doorbells — because the connection gets lost "
            "between the routers. Putting the outer router into bridge "
            "or access-point mode usually fixes it."
        ),
        "doc": "DIAGNOSIS-RULES.md#nat-1--double-nat-detected",
    },
    {
        "id": "NAT-1b",
        "title": "ISP-side private routing",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your ISP routes your traffic through their own internal "
            "private network before it reaches the public internet — "
            "a normal part of their infrastructure, not a fault on your "
            "end. It's surfaced because it explains why a traceroute "
            "shows private-network addresses partway along the path."
        ),
        "doc": "DIAGNOSIS-RULES.md#nat-1b--isp-side-private-transit-not-your-double-nat",
    },
    {
        "id": "BL-1",
        "title": "Metric regressed vs. history",
        "category": "baseline",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "One or more measurements from this run are noticeably worse "
            "than what's typical for this specific network, based on its "
            "own recent history. An absolute threshold can miss this kind "
            "of regression when the number still looks fine in isolation; "
            "which metric moved, and by how much, is named in the "
            "diagnosis text."
        ),
        "doc": "DIAGNOSIS-RULES.md#bl-1--a-metric-regressed-against-this-networks-own-history",
    },
    {
        "id": "CP-1",
        "title": "Captive portal blocking access",
        "category": "internet",
        "severity": "varies",
        "scope": "both",
        "blurb": (
            "The check for internet access came back intercepted rather "
            "than answered, which is the signature of a captive portal — "
            "the login or terms page hotel, airport, and coffee-shop WiFi "
            "often require before real internet access works. Open a "
            "browser and complete the portal; nothing else will work "
            "until it's accepted. Critical when nothing is getting "
            "through, a warning when traffic still flows and the portal "
            "is only waiting to cut it off."
        ),
        "doc": "DIAGNOSIS-RULES.md#cp-1--captive-portal-blocking-real-access",
    },
]


# One entry per jargon term the report card shows. `key` is what a GUI
# looks the entry up by — chosen to match `RunReportView`'s own row
# concepts (`router`, `internet`, `dns`, `wifi_signal`, `bufferbloat`,
# `mtu`, `speed`, `clock`) plus three terms that show up *inside* a row's
# value text rather than as a row of their own (`packet_loss`, `latency`,
# `jitter`) — "3.4 ms · 2% loss" reads as two unexplained numbers without
# them. Order is reading order for a plain listing, not meaningful to a
# lookup.
METRICS: list[dict[str, str]] = [
    {
        "key": "router",
        "label": "Router",
        "help": (
            "The box in your home that gets your other devices onto the "
            "internet — sometimes combined with your modem into one unit. "
            "A problem here means the fault is close to home, not out on "
            "the wider internet."
        ),
    },
    {
        "key": "internet",
        "label": "Internet",
        "help": (
            "The wider internet beyond your own router — your provider's "
            "network and everything past it. A problem measured here "
            "usually sits outside your home, even though your Mac is the "
            "one doing the measuring."
        ),
    },
    {
        "key": "dns",
        "label": "Name lookups (DNS)",
        "help": (
            "Every website name, like example.com, has to be translated "
            "into a numeric address before your Mac can reach it. That "
            "translation is called DNS — when it's slow or failing, sites "
            "feel like they won't even start loading."
        ),
    },
    {
        "key": "wifi_signal",
        "label": "Wi-Fi signal",
        "help": (
            "How strong the wireless connection is between your Mac and "
            "the router. A weak signal causes stalls and dropped "
            "connections even when the rest of your network is healthy."
        ),
    },
    {
        "key": "bufferbloat",
        "label": "Under load",
        "help": (
            "What happens to your connection's responsiveness while it's "
            "busy — for example, while something is uploading or "
            "downloading heavily. A router that gets sluggish under load "
            "can make a video call choppy even though your everyday speed "
            "looks fine."
        ),
    },
    {
        "key": "mtu",
        "label": "Packet size (MTU)",
        "help": (
            "The biggest chunk of data your connection can send in one "
            "piece. If it's smaller than usual, some websites and video "
            "calls can stall or fail to load."
        ),
    },
    {
        "key": "speed",
        "label": "Speed",
        "help": (
            "How fast data actually moves over your connection right now "
            "— download is data coming to you, upload is data you send "
            "out. Neither one measures your everyday latency."
        ),
    },
    {
        "key": "clock",
        "label": "Clock",
        "help": (
            "Your Mac's own sense of the current time. Secure websites "
            "check this against their own certificates, so a clock "
            "that's drifted can make secure connections fail outright."
        ),
    },
    {
        "key": "packet_loss",
        "label": "Packet loss",
        "help": (
            "Small pieces of data, called packets, that were sent but "
            "never arrived. Even a little loss causes stutters in calls "
            "and games; a lot of it makes a connection feel broken."
        ),
    },
    {
        "key": "latency",
        "label": "Latency / ping",
        "help": (
            "How long it takes a single message to make a round trip to "
            "something and back. Lower feels snappier; high latency is "
            "what makes a call feel like it's lagging behind."
        ),
    },
    {
        "key": "jitter",
        "label": "Jitter",
        "help": (
            "How much latency varies from one moment to the next. Even "
            "when the average is fine, big swings in jitter are what "
            "make a call or a game feel unpredictable and stuttery."
        ),
    },
]


_FIELDS = frozenset({"id", "title", "category", "severity", "scope", "blurb", "doc"})
_METRIC_FIELDS = frozenset({"key", "label", "help"})


def _validate(rules: list[dict[str, str]]) -> None:
    """Fail loud on a malformed entry rather than ship a silent typo.

    The bats suite re-checks all of this from the emitted JSON too, so
    this exists for the case that matters more: someone runs this helper
    by hand, outside the test suite, and a bad edit to RULES should not
    reach them as a mysteriously wrong report-card tint six months later.
    """
    seen_ids: set[str] = set()
    for r in rules:
        assert set(r) == _FIELDS, f"entry has the wrong field set: {r}"
        for k, v in r.items():
            assert isinstance(v, str) and v.strip(), f"{r.get('id')}.{k} is empty"
        assert r["category"] in CATEGORIES, f"{r['id']}: bad category {r['category']!r}"
        assert r["severity"] in SEVERITIES, f"{r['id']}: bad severity {r['severity']!r}"
        assert r["scope"] in SCOPES, f"{r['id']}: bad scope {r['scope']!r}"
        assert r["id"] not in seen_ids, f"duplicate rule id: {r['id']}"
        seen_ids.add(r["id"])


def _validate_metrics(metrics: list[dict[str, str]]) -> None:
    """Same discipline as `_validate`, for the glossary array."""
    seen_keys: set[str] = set()
    for m in metrics:
        assert set(m) == _METRIC_FIELDS, f"entry has the wrong field set: {m}"
        for k, v in m.items():
            assert isinstance(v, str) and v.strip(), f"{m.get('key')}.{k} is empty"
        assert m["key"] not in seen_keys, f"duplicate metric key: {m['key']}"
        seen_keys.add(m["key"])


def main() -> None:
    _validate(RULES)
    _validate_metrics(METRICS)
    doc = {
        "schema": SCHEMA_RULES_CATALOG,
        "version": os.environ.get("NETDIAG_RULES_VERSION") or None,
        "rules": RULES,
        "metrics": METRICS,
    }
    json.dump(doc, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # One-shot writer like capabilities.py: this only silences the
        # traceback when a consumer closes early (e.g. a `| head -c1`).
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
