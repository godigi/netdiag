# Diagnosis rules

> Every rule the diagnosis engine emits is documented here with: what it
> triggers on, what evidence it cites, what severity it carries, and the
> rationale. Rules are ranked by severity × confidence; the highest-ranked
> rule is surfaced as `most_likely_root_cause` in the JSON output.
>
> **As of v0.4.0** the canonical user-facing string for each rule lives
> in the bash module that emits it (`lib/diagnosis.sh`, `lib/wan.sh`,
> `lib/output.sh`). The strings are written in plain English (symptom →
> cause → action, with technical terms parenthetical for power users).
> This file documents the trigger/evidence/rationale for rule
> maintainers; grep the bash sources for the literal `add_diag` calls
> if you need the exact user text.

## Rule IDs

Every rule has an ID (`W1`, `NAT-1`, `BL-1`, …) matching a heading below.
`add_diag` records it, `--expert` prefixes each diagnosis with `[ID]`, and
the JSON carries it as `diagnosis[].rule`. Filter on the ID rather than on
the prose — the wording is deliberately rewritten for readability and will
keep changing; the ID won't.

## Severity

- `critical` — the network is unusable or about to be.
- `warn` — performance is degraded or a known foot-gun is active.
- `info` — surfaced for context, not actionable on its own.

## Rules in the v0.1.0 starter

The original script emits the rules below. Replacing them with the ranked
engine is a future step; for now they're listed verbatim for traceability.

### N1 — No network at all

**Fires when:** `GATEWAY` is empty **and** `LINK_UP` is 0 — no default
route, and no active interface holding an address.

**Severity:** critical.

Every other rule keys off a measurement that only exists once there is a
link — gateway loss, public reachability, DNS answers. Before this rule
existed, a Mac with WiFi switched off produced *zero* diagnoses and
exited 0 with "Nothing obviously wrong — your network looks healthy",
because each rule's guard (`[ -n "$GW_LOSS" ]` and friends) short-circuited
on the missing data. N1 is the floor: it fires first, states the obvious,
and makes the exit code 2.

**The `LINK_UP` condition is load-bearing and was added after the fact.**
N1 originally fired on the missing route alone and told the user their Mac
"isn't joined to a WiFi network and has no working ethernet link" — a
claim nothing in the run had checked, and one the same report contradicted
three lines higher by printing the SSID and the signal strength. See N1c.

A second, narrower branch covers focused runs: `--mtu-only` skips the
gateway section, so `PUBLIC_OK=0` with an empty `GW_LOSS` can't reach P1
or P2. That branch — N1b, documented in full further down — points the
user at a full run rather than guessing.

### N1c — Joined with no route out

**Fires when:** `GATEWAY` is empty **and** `LINK_UP` is 1 — an active
interface holding an address, with no default route.

**Severity:** critical. The network is unusable, which is what critical
means; the fact that the fix may be thirty seconds in a browser doesn't
make the current state any less broken.

**Evidence:** the SSID (or "ethernet"), and `LINK_DHCP_ROUTER` when the
DHCP server offered one.

**Recommendation:** open a browser and pass the network's sign-in page,
starting at `http://<LINK_DHCP_ROUTER>`.

**Rationale.** "Address but no route" is a real and distinct network
state, and the overwhelmingly most common cause of it is a captive portal
that hasn't been passed. N1c leads with that rather than enumerating
causes evenly, because it is also the only cause the user can act on
without finding the network's owner.

**N1c never claims a portal was detected.** It cannot: with no default
route the canary at `captive.apple.com` is unreachable, so there is
nothing to detect. It says what was observed — joined, addressed, no
route — and then says what to try. CP-1 is the rule that gets to assert a
portal, and only when the probe confirms one.

**Why the DHCP router is quoted rather than the (absent) gateway.**
`ipconfig getpacket` carries the router option whether or not the kernel
installed a route to it, so on exactly the networks where N1c fires there
is still a concrete address to point a browser at. `lib/linkstate.sh`
parses it; `lib/netid.sh` also uses it as a last-resort identity so these
runs stop filing under the synthetic "unknown" network.

### W1 — Weak WiFi signal

- Trigger: `wifi.rssi < -75`
- Severity: `warn`
- Recommendation: move closer to the AP, or switch bands/AP.

### W2 — Low WiFi SNR

- Trigger: `wifi.snr < 20 dB`
- Severity: `warn`
- Recommendation: change channel — interference on the current one.

> **G1, G2 and G3 all fire only when `TCP-1` does not.** A gateway that
> drops pings while still carrying TCP is filtering, not failing; see the
> precedence note under TCP-1 below. The trigger lines here read as
> `... AND NOT TCP-1`.

### G1 — Gateway loss + weak WiFi

- Trigger: `gateway.loss_pct >= 20 AND wifi.rssi < -70`
- Severity: `critical`
- Recommendation: WiFi link is the problem, not the router or ISP.
- Wording: the printed text calls the router "the box that gives you
  internet in your home" and says explicitly that the loss is "not out on
  the wider internet" — see the rationale under G3, which explains why
  G1/G2/G3 all spell this out in plain words rather than assuming the
  reader knows a router isn't the internet.

### G2 — Gateway loss with healthy WiFi

- Trigger: `gateway.loss_pct >= 20 AND NOT W1`
- Severity: `critical`
- Recommendation: router itself is misbehaving — reboot it.

### G3 — Gateway loss below the critical floor

- Trigger: `LOSS_WARN_PCT <= gateway.loss_pct < 20` (i.e. 10–19%)
- Severity: `warn`
- Evidence: gateway loss%.
- Recommendation: branches on what was actually measured, the same shape
  G1/G2 use above it:
  * WiFi with `wifi.rssi <= THRESH_WIFI_RSSI_WEAK_DBM`, or a measured
    `wifi.snr < THRESH_WIFI_SNR_LOW_DB` — blame the weak signal; move
    closer to the router or switch to a less crowded band/channel.
  * WiFi with a good signal — Wi-Fi interference (microwaves,
    neighbouring networks, distance) is still the most common cause at
    this level; a router restart helps if it persists.
  * Ethernet — the cable or the switch port.
- Rationale: G1/G2 start at 20%, and until v0.6.0 nothing covered the band
  beneath them. The Report card coloured its Router row yellow from 1%
  upward, but colour is not a diagnosis: `ok()`/`warn()`/`bad()` are pure
  printers and only `add_diag` moves `MAX_SEVERITY`. So 15% loss to the
  user's own router printed a yellow row directly above "Nothing obviously
  wrong — your network looks healthy" and exited 0. At that rate every
  page load stalls on a retransmit and calls break up.
- Wording amendment: a non-technical reader does not reliably know that
  "your router" and "your internet" are different things, so a message
  that names only the router still gets read as "my internet is broken" —
  and from there, as the ISP's fault. G1/G2/G3 now say in plain words that
  the loss is on the connection *inside the home*, not with the internet
  provider, and G3 additionally says the internet service itself looks
  fine from here. Each also names the likely cause instead of stopping at
  the verdict: Wi-Fi signal/interference, or on ethernet, the cable/port.

### P1 — DNS down, public unreachable

- Trigger: `public.ok == false AND gateway.loss_pct < 20 AND dns.ok == false`
- Severity: `critical`
- Recommendation: DNS or upstream ISP outage.

### P2 — Public unreachable, DNS up

- Trigger: `public.ok == false AND gateway.loss_pct < 20 AND dns.ok == true`
- Severity: `critical`
- Recommendation: ISP-side outage.

> **Threshold amendment (v0.6.0).** Both guards were `gateway.loss_pct == 0`
> exactly. Adding G3 exposed the hole that created: an outage measured
> alongside, say, 8% gateway loss matched neither P1/P2 (loss was not zero)
> nor G1/G2 (loss was under 20), so a total loss of internet produced no
> diagnosis at all. The guard now means "the router is not the problem",
> not "the router is flawless". It is `loss_below`, not `! loss_at_least`,
> so a gateway that was never measured does not read as clean.

### L1 — Severe internet-side packet loss

- Trigger: `inet.loss_pct >= 20 AND inet.loss_pct_alt >= 20 AND
  gateway.loss_pct < 10 AND NOT ICMP-1`
- Severity: `critical`
- Evidence: loss% to both public targets, gateway loss% for contrast.
- Recommendation: the fault is past the user's own router — the line, the
  modem, or the ISP. Reboot the modem once, then report the loss figures.
- Rationale: this is the gap that motivated the whole v0.6.0 rule set.
  `INET_LOSS` had been measured, written to JSON, and used to colour a
  Report-card row since v0.4.0, but **no rule ever read it**. P1/P2 could
  not cover the case because they require `public.ok == false`, and under
  heavy-but-partial loss curl still succeeds — TCP simply retransmits its
  way through. The result: 40% loss upstream of a clean router printed a
  red "Latency" row immediately above "Nothing obviously wrong" and exited
  0. That is precisely the state a user describes as "the internet is
  down" — everything technically works, nothing finishes.
- Why two targets: 1.1.1.1 and 8.8.8.8 are probed independently and both
  must exceed the threshold. One lossy target and one clean one is far
  more likely to be that anycast operator rate-limiting ICMP than a fault
  on the user's line, and caps out at L2.

### L2 — Moderate internet-side packet loss

- Trigger: `(inet.loss_pct >= 10 OR inet.loss_pct_alt >= 10) AND
  gateway.loss_pct < 10 AND NOT L1 AND NOT ICMP-1`
- Severity: `warn`
- Evidence: loss% to both public targets.
- Recommendation: re-run when it feels worst; report if it persists. Often
  time-of-day congestion on the ISP's local segment.

### ICMP-1 — Ping filtered upstream, real traffic fine

- Trigger: `inet.loss_pct == 100 AND inet.loss_pct_alt == 100 AND
  public.ok == true AND tcp_reach.any_ok == true`
- Severity: `info`
- Evidence: both targets at 100%, contrasted with working curl and TCP.
- Recommendation: none — the connection is fine, the latency numbers just
  can't be measured.
- Rationale: total loss to both public targets *while curl fetched a page
  and TCP/443 connected* is not an outage; real 100% loss would have taken
  both of those with it. It is an ISP or middlebox dropping ICMP wholesale,
  which is common. Without this guard L1 would announce an ISP fault on a
  perfectly good link — the same false-critical shape as the ping6 bug
  fixed in v0.5.2. ICMP-1 is checked first and suppresses L1 and L2.
  TCP-1 covers the analogous case one hop earlier, at the gateway.

### Loss thresholds and how the probe is measured

`LOSS_WARN_PCT` (10) and `LOSS_CRIT_PCT` (20) are defined in
`lib/globals.sh` and shared by every rule above *and* by the Report card,
so a coloured row always has a matching diagnosis beneath it.

Each probe sends 20 packets at 0.2 s spacing, which puts the reportable
quantum at 5%. Both thresholds land on a whole number of dropped packets —
warn at two, critical at four — and a bats test enforces that, because the
original 8-packet probe made every threshold below 12.5% unexpressible.

Warn sits at two drops rather than one as a **judgement call**: a clean
link reports 0.0% on both targets in every trial, so a 5% floor would not
misfire here, but a single transient drop in twenty is an ordinary event
on real links and warning on it across the user base would be noise.

#### ping's `-t` flag corrupted every loss measurement

Worth recording, because it invalidated an earlier version of this very
section. On macOS, `ping -t` is a deadline for the **whole run** — not a
per-packet TTL, which is what `-c 8 -t 2` looks like it means. Measured:

| Command | Result |
|---|---|
| `ping -c 20 -i 0.2 -t 2` | **10** packets transmitted — half the probe silently discarded |
| `ping -c 20 -i 0.1 -t 2` | 20 sent, 19 received, **"5.0% loss"** — the last reply lands after the deadline |
| `ping -c 20 -i 0.1` | 20/20, **0.0%**, every trial, both targets |
| `ping -c 20 -i 0.2` | 20/20, **0.0%**, every trial, both targets |

So a healthy link reported a permanent 5% loss floor, and a probe asked
for 20 packets sent 10. An earlier draft of this document explained that
5% as ICMP rate-limiting by the anycast operators and set the warn floor
above it on that basis — the explanation was wrong, and the evidence for
it was the bug. `-t` is now absent from both loss probes; `with_timeout`
supplies the outer bound instead, since it cannot corrupt the measurement.
A regression test greps for the flag's return.

#### The probe runs serially

`internet_ping_run` was moved out of the parallel batch in v0.6.0.
Measuring loss while DNS, TCP, NTP, the WiFi scan and two WAN checks
compete for the same interface measures the tool, not the network. The
first full run with the probe in the batch reported 30% loss on a link an
isolated probe showed to be clean; most of that was the `-t` truncation
above, but the methodology is wrong regardless, and this number now
decides a critical diagnosis. It costs ~4 s.

### D1 — Partial DNS, internet reachable

- Trigger: `dns.ok == false AND public.ok == true`
- Severity: `warn`
- Recommendation: change resolver (1.1.1.1 or 8.8.8.8).

### D2 — No name lookups working at all

- **Trigger:** `DNS_LINES` non-empty (the check ran), `dns.ok == false`,
  and `public.ok == false`.
- **Severity:** warn. The connection failure it accompanies is already
  critical; a second critical would double-count one fault.
- **Recommendation:** fix the connection first, then re-test DNS.

**Precedence: D1 and D2 are mutually exclusive**, split on `public.ok`.
D1 is the partial case and says "everything else works, so it's your
resolver" — a sentence that is only true when everything else does work.
D2 is the total case and deliberately declines to blame the resolver.

**Why D2 exists.** D1's `public.ok == true` guard meant a network with no
internet fired *no* `dns`-category rule at all, however badly DNS was
failing. `RunReportView` colors the "Name lookups (DNS)" row from the
categories of the rules the CLI hands it, so the report card showed a
green dot beside the words "0 of 6 resolvers OK" — visible in the
screenshots that prompted this work. The row was right and the dot was
wrong, and the missing piece was a rule, not a renderer: per CLAUDE.md the
GUI holds no diagnostic logic, so a threshold or verdict added to Swift to
paper over this would have been the wrong fix in the wrong file.

### D3 — Slow DNS resolver latency

- Trigger: `dns.resolver_ms > 250 AND dns.ok == true`
- Severity: `warn`
- Evidence: query response time in ms from primary system resolver.
- Recommendation: change resolver to Cloudflare (1.1.1.1) or Google (8.8.8.8) in network settings.
- Rationale: High DNS latency stalls initial TCP/TLS connections for every new domain or hyperlink clicked.

### D4 — DNS hijacking and search redirection

- Trigger: non-existent domain query returns an IP address instead of NXDOMAIN
- Severity: `warn`
- Evidence: redirected IP returned by system resolver.
- Recommendation: switch to public DNS (1.1.1.1 / 8.8.8.8) or enable Encrypted DNS (DoH).
- Rationale: ISPs intercept failed queries to show search ads or track user activity.

### B1 — Bufferbloat at gateway hop

- Trigger: `bufferbloat.gw_grade ∈ {C, D, F}`
- Severity: `warn` (C) / `critical` (D, F)
- Evidence: idle gw RTT, loaded gw RTT, delta in ms, grade.
- Recommendation: router lacks SQM/fq_codel. Enable Smart Queue Management
  in the router UI, or replace with a router that supports cake/fq_codel.
- Rationale: the latency spike happens before traffic ever leaves the LAN,
  so the queue depth lives in your router's WAN egress buffer.

### B2 — Bufferbloat at ISP hop only

- Trigger: `bufferbloat.inet_grade ∈ {C, D, F}`
- Severity: `warn` (C) / `critical` (D, F)
- Evidence: idle internet RTT, loaded internet RTT, delta, grade.
- Recommendation: your ISP's CPE/uplink is the bottleneck. Call the ISP;
  if you control the modem, try a firmware update.

## Rules added for the 14 enhancements

All of the below are implemented and can fire.

### M1 — Path MTU below 1500

- Trigger: `mtu.effective < 1500`
- Severity: `warn` (1400–1499) / `critical` (< 1400)
- Evidence: largest DF-set payload that got through and the inferred MTU.
- Recommendation: classic symptom of PPPoE / VPN / tunnelled link. Add MSS
  clamping at the router or shrink the WAN MTU.
- Rationale: TLS ClientHello + cert chain push frames to the path-MTU
  ceiling; if DF is set and the router doesn't return ICMP frag-needed, the
  handshake hangs while smaller-frame sites still work.

### MT1 — First lossy hop identified

- Trigger: a hop in the `mtr -r -c 60 -i 0.2` report (or the per-hop
  fallback) shows > 2% loss while the immediately previous hop had ≤ 2%.
- Severity: `warn`.
- Evidence: hop number and IP, the loss% on that hop and the previous one.
- Recommendation: blame this hop (and the router/ISP that owns it). Loss
  on later hops is usually inherited, not new.
- Rationale: each ICMP TTL-exceeded reply comes from a different router;
  routers further along the path may rate-limit ICMP, faking "loss" that
  doesn't affect real traffic. The first hop where loss appears is the
  one actually dropping packets.
### V6-1 — IPv6 broken while IPv4 works

- Trigger: `ipv6.available == true AND public.ok == true AND
  (ipv6.ping_loss >= 20% OR ipv6.aaaa_ok == false OR ipv6.tcp_v6_ok == false)`.
- Severity: `warn` (Happy Eyeballs will hide it for most traffic).
- Evidence: ping6 loss, AAAA OK?, TCP/443 to ipv6.google.com OK?
- Recommendation: router or ISP IPv6 misconfig. Reboot the router; if it
  persists, ask the ISP whether they've actually provisioned a v6 prefix.
- Rationale: macOS Happy Eyeballs races v4 and v6, picking the first
  responder. A degraded v6 path slows down loads of v6-preferred sites
  (large-CDN, Google, Cloudflare) by exactly the timeout window before
  v4 wins, ~250 ms — enough to feel like "the internet is laggy" without
  any v4-side culprit.
### V6-2 — Unresponsive IPv6 DNS resolver

- Trigger: an IPv6 nameserver is configured in system settings but fails to respond while IPv4 DNS works.
- Severity: `warn`
- Evidence: unresponsive IPv6 nameserver address from `scutil --dns`.
- Recommendation: update router IPv6 configuration or disable IPv6 in network settings if unsupported by ISP.
- Rationale: macOS queries IPv6 DNS first, waiting 2–3 seconds for a timeout before falling back to IPv4.
### VPN-1 — VPN is carrying the default route

- Trigger: `vpn.active == true` (any of: scutil --nc shows Connected,
  tailscale status BackendState==Running, default route via utun*/wg*).
- Severity: `info` (it's a heads-up, not a fault).
- Evidence: VPN type and name.
- Recommendation: the "gateway" line is the VPN endpoint, not your LAN
  router. RTT, loss, and traceroute reflect the tunnel — for a true
  picture of the local link, disconnect the VPN and run netdiag again.
- Trigger: `vpn.active == true`. Severity: `info`, so it never changes the
  exit code — an intentional VPN is not a fault.
- Emitted since v0.6.0. Between v0.1.0 and v0.5.2 this file and the README
  both promised the rule while `lib/vpn.sh` only printed a section line and
  no `add_diag` call existed anywhere, so an active VPN never reached the
  Diagnosis section at all.
- Rationale: users blame the router when the VPN is the actual
  bottleneck. Surfacing this up-front saves the support volley.
### TCP-1 — TCP works, ICMP is filtered

- Trigger: `tcp_reach.any_ok == true AND gateway.loss_pct >= 50`.
- Severity: `info` (the network is fine; ICMP is misleading).
- Evidence: which TCP probes succeeded, gateway loss%.
- Recommendation: ignore the ping-based failures — connectivity is up.
  ISPs / corporate gateways / hotel WiFi often block ICMP echo while
  letting TCP through.
- Rationale: ping-based diagnostics conflate "ICMP works" with "network
  works." A green TCP panel + red ICMP panel is the textbook tell.
- **Precedence: TCP-1 suppresses G1, G2 and G3.** It is evaluated before
  them, in both `lib/diagnosis.sh` and `lib/monitor.sh`, and when it fires
  the gateway-loss rules do not. Until this was so, both fired together and
  the report carried "reboot the router (unplug it for 30 seconds)"
  immediately above "the network is up; don't worry about the ping numbers
  above" — with the critical one owning the headline and the exit code, so
  every hotel and corporate network scored a `2`. TCP reaching 1.1.1.1:443
  means packets *are* crossing the gateway, so the gateway is forwarding and
  merely declining to answer pings itself; `THRESH_ICMP_FILTERED_LOSS_PCT`
  is deliberately set well above `LOSS_CRIT_PCT` so that inference is safe.
  No figure is lost — TCP-1's own text quotes the gateway loss percentage.
  If TCP is *not* reaching anything, there is no evidence the gateway
  forwards at all, TCP-1 does not fire, and G1/G2/G3 call the loss what it
  is.

### WS-1 — WiFi channel is congested

- Trigger: `wifi_scan.current_channel_neighbors > 3`.
- Severity: `warn`.
- Evidence: current channel, count of neighbour APs on it.
- Recommendation: switch to a less crowded channel — for 5GHz, try the
  upper UNII-3 block (149/153/157/161) which most consumer routers don't
  pick by default.
- Limitation: macOS Tahoe doesn't expose neighbour RSSI via
  `system_profiler`, so we can only count APs, not weight by signal
  strength. A neighbour with -90 dBm is "noise floor only" and doesn't
  really compete, but we count it the same as a -50 dBm AP next door.
### WD-1 — WiFi link is flapping

- Trigger: `wifi_disconnects.count > 3` over a 1-hour window.
- Severity: `warn`.
- Evidence: count + last 5 events from `log show`.
- Recommendation: roaming between APs, marginal signal at the desk, or
  a router firmware bug. If sticky/asymmetric roaming is suspected,
  disable the lower band's "auto" or split SSIDs by band.
- **ST-1** — Speed regression vs baseline.
### NT-1 — System clock drift > 30 s

- Trigger: `|ntp.drift_seconds| > 30`.
- Severity: `warn` or `critical`, by magnitude — the same call site
  grades smaller drifts down (the catalog says `varies`).
- Evidence: drift in seconds from `sntp -t 3 time.apple.com`.
- Recommendation: re-enable network time (System Settings → General →
  Date & Time → Set automatically).
- Rationale: TLS validates cert NotBefore/NotAfter against the system
  clock. > 30 s drift starts breaking handshakes on certs near their
  rotation window; days of drift breaks everything. Users see this as
  "nothing loads" without any network-level fault to blame.
- **BL-1** — Metric regression vs 30-day median (gateway RTT, RSSI, PMTU, etc.).
### DI-1 — Router unreachable at the hardware (ARP) layer

- Trigger: the gateway IP is marked `(incomplete)` in `arp -an`.
- Severity: `critical`.
- Evidence: the `(IP) at (incomplete)` line for the gateway.
- Recommendation: L2 to the router is broken — check the ethernet cable,
  the WiFi connection, or that the right router is actually set as the
  default gateway.
- Rationale: nothing above this in the stack matters if ARP can't
  resolve the router at all. Surface it early. Split from DI-2 (below)
  so "the router is unreachable at layer 2" and "two devices share an
  address" don't share a message — they have different causes and
  different fixes.

### DH-1 — DHCP lease expires within 1 hour

- Trigger: `dhcp.time_remaining_s < 3600`.
- Severity: `warn`.
- Evidence: lease expiration time + computed minutes remaining.
- Recommendation: if a renewal fails (router rebooting or DHCP scope
  exhausted), the link will drop without warning. Watch for it.

### DH-2 — DHCP-handed DNS differs from system resolver

- Trigger: `dhcp.dns_servers` does not contain `system.resolver`.
- Severity: `info`.
- Evidence: both addresses side-by-side.
- Recommendation: fine if intentional; surprising otherwise. Common
  cause: user manually set 1.1.1.1 or 8.8.8.8 in System Settings.

### V6-3 — The network is IPv6-only, by design

- Trigger: `IPV6_AVAILABLE`, `IPV6_AAAA_OK` and `IPV6_TCP_OK` all set,
  **and** the IPv4 `GATEWAY` is empty (`ipv6_is_v6_only`).
- Severity: `info`.
- Evidence: whether macOS set up a CLAT translator (`IPV6_CLAT`, an
  address in `192.0.0.0/29` per RFC 7335).
- Recommendation: none. Nothing is wrong.

**It heads the `N1` chain, and that placement is the whole rule.**
netdiag's `GATEWAY` comes from `route -n get default`, which is IPv4 —
so a network that is IPv6-only leaves it empty and the run falls into
`N1c` ("joined with no route out") or `N1` ("no network connection at
all"). Both are critical, both exit 2, and both are false on a network
working exactly as intended and carrying the user's traffic perfectly
well. IPv6-only networks are normal on some mobile carriers,
universities and newer corporate deployments, and growing.

`V6-1` is the mirror of this and has existed for versions: broken IPv6
alongside working IPv4. This direction had no rule at all.

**The guard demands IPv6 be proven, not merely present.** A global
address is not enough — `V6-1` exists precisely because a
half-configured IPv6 stack is common. A real TCP connection over IPv6
plus a working AAAA lookup is the evidence that this network carries
traffic. Without both, an absent IPv4 gateway is a genuine outage and
`N1`/`N1c` go on saying so.

**Not verified against a real IPv6-only network.** The author had none
to hand: this machine is IPv4-only (`scutil --nwi` reports "No IPv6
states found"). The predicates are pure and fixture-tested, and the
CLAT range is RFC 7335's, but the end-to-end behaviour on an actual
NAT64 network is unconfirmed.

## What else is in the path

`VPN-2`, `PX-1` and `FW-1` all exist for one reason: **netdiag equates
"carries my traffic" with "holds the default route"**, and macOS stopped
honouring that equation years ago. Split tunnels, PAC proxies,
NetworkExtension content filters, per-app proxies and DoH resolvers each
sit in the datapath *without* taking the default route — so every
measurement in the report still reads as a clean description of "the
network" while a different subset of it quietly stops describing what
the user's traffic actually does.

They were designed as one check (`lib/path.sh`) rather than five
features, because they are one bug wearing five disguises. The module
does not diagnose faults; it enumerates actors and says which
measurements each one undermines.

**All three are `info`, and worded as "here is something else in the
path" rather than as an accusation.** A split tunnel, a corporate proxy
and a content filter are usually working exactly as their owner
intended, and a network tool crying wolf about corporate security
software is worse than silence. What they add is the one sentence that
stops a user trusting a clean report while their work applications are
broken.

**Two actors are deliberately absent.** iCloud Private Relay and
encrypted DNS (DoH/DoT) both belong here, and neither ships, for the
same reason: the detection has never been observed in its *positive*
state. See `docs/design/networks-we-cannot-yet-describe.md` §2.2 and
§2.3 — the Private Relay mechanism is proven and only its value mapping
is unverified. A rule that fires on a value nobody has seen is a rule
that has never been tested.

### VPN-2 — A split tunnel carries part of your traffic

- Trigger: `netstat -rn -f inet` shows a **non-default** route via a
  `utun*` / `ipsec*` / `wg*` / `ppp*` interface.
- Severity: `info`.
- Evidence: the tunnel interfaces carrying routes.

`VPN-1` fires on the *default route*. A corporate split-tunnel VPN
deliberately does not take it — it installs routes for the company's
prefixes only — so netdiag reported a perfectly healthy network while
every work application was broken, and said nothing about the one
component that was failing.

**Interfaces are not evidence; routes are.** The machine this was
written on has `utun0` through `utun5` all UP and carrying no routes
whatsoever. macOS creates them as a matter of course, which is why
`lib/vpn.sh` already warns that "existence alone is meaningless" — and
why this rule keys on the routing table instead.

### PX-1 — A proxy or PAC file is configured

- Trigger: `networksetup -getwebproxy` or `-getautoproxyurl` reports
  `Enabled: Yes` for the service carrying the link.
- Severity: `info`.
- Evidence: `host:port`, or the PAC URL.

On a managed Mac a PAC file decides which destinations go direct and
which go through a proxy, so `tcp_reach`'s direct connections test a
path real traffic never uses. Nothing in netdiag read these settings
before. Checked only for `LINK_SERVICE` — proxy settings are per-service
and only the service carrying this run's traffic is relevant.

### FW-1 — Network filtering software is in the path

- Trigger: `systemextensionsctl list` reports one or more extensions
  under `com.apple.system_extension.network_extension`.
- Severity: `info`.
- Evidence: the bundle IDs.

Zscaler, Netskope, Cloudflare WARP, Little Snitch and LuLu install
NetworkExtension content filters that sit in the datapath. When one
misbehaves it *is* the fault, and netdiag would otherwise attribute its
symptoms to the router or the ISP.

Only the `network_extension` group counts. This machine has a camera
extension and a driver extension installed; neither is in the datapath,
and reporting them would be a false alarm on a very common setup.

### DQ-1 — The run measured two networks

- Trigger: `netid_fingerprint_live` taken once after `dhcp_run` and again
  before `diagnosis_run` differ (`netid_fingerprint_changed`).
- Severity: `info`.
- Evidence: none quoted — the fingerprint carries the SSID and BSSID,
  and naming them would put a second network's identity in a report
  filed under the first.
- Recommendation: settle on a connection and re-run.

**The defect it closes.** A full check takes ~60 s. Walk out of Wi-Fi
range onto ethernet at second 30 and the run blends two networks: a
latency figure from one link, a speed figure from another, and a single
`network.id` stamped on both. It then goes into that network's history,
where `BL-1` judges every future run against a baseline describing a
transition. Roaming between two mesh APs does the same to `W1`/`W2` —
one averaged RSSI describing neither radio.

**It also changes what is stored, which is the larger half.**
`lib/output.sh` forces `NO_BASELINE=1` and `HISTORY_APPEND=0` on this
flag. Comparing a blend against either network's history manufactures
`BL-1` regressions out of the switch itself; *storing* it poisons the
baseline every future run on that network is measured against. Silently
filing it under one of the two was what happened before this rule.

**Why a fingerprint rather than a second `netid_run`.** Re-deriving
`NETWORK_ID` means re-running `iface`, `wifi` and `arp` — tens of
seconds to answer a question that four fast reads settle. The
fingerprint (interface, gateway, SSID, BSSID) costs ~15 ms and is not
the network's identity; it is a tripwire for the identity changing.

**An unreadable fingerprint is never a change.** If either reading comes
back empty — or as `|||`, every field blank, which an unprivileged
routeless run produces — the rule stays silent. A warning that fires on
every run is a warning nobody reads, and absence of a reading is not
evidence of a change.

### WI-1 — macOS is withholding the network's name

- Trigger: on Wi-Fi, `WIFI_NAME_HIDDEN == 1` — `lib/wifi.sh` saw the
  SSID come back `<redacted>` or empty.
- Severity: `info`.
- Evidence: none needed; the absence is the finding.
- Recommendation: grant Location Services to the terminal.

**A data-completeness fact, not a network fault**, and the reason it is
a diagnosis rather than the log line it used to be is that the *stored*
consequence is what bites. Every run on a nameless network is filed
under `WiFi (SSID hidden by macOS)`, so runs on genuinely different
networks merge into one history and a per-network baseline can end up
comparing a café against an office.

This project has three real Wi-Fi flapping episodes in its own recorded
history — 112, 241 and 173 disassociations inside an hour — and cannot
confirm they were even on the same network, for exactly this reason.
The two `info` lines in `lib/wifi.sh` were suppressed in a default run,
so nobody saw the problem until the data was already unusable.

**Related instrumentation.** Two other gaps from the same investigation
are closed alongside this rule, neither of them a rule:

- `wifi.privileged` records whether the sudo-only scrape ran. Without
  it, `rssi`, `noise`, `snr`, `channel`, `phy` and `tx_rate` being
  `null` is ambiguous between "measured and quiet" and "never
  measured". Every radio field in those three stored spikes is null,
  and nothing said which — so there is no way to tell a weak-signal
  drop from an interference drop from an AP-side problem.
- `wifi_disconnects.events` stores the condensed event lines behind the
  count, capped at `THRESH_WIFI_EVENTS_STORED` (50) and newest last.
  The report still shows five, because the 2 KB-per-line `airportd`
  dumps would drown everything else; the record keeps more. macOS's log
  retention rolls over long before anyone investigates, so a line not
  captured at run time is gone.

### MET-1 — Metered connection

- Trigger: `LINK_METERED == 1`, set by `linkstate_run` when either the
  macOS service name carrying the link is a tethered one
  (`linkstate_is_tethered_service`) or the address falls in a phone
  hotspot's documented default range (`linkstate_is_hotspot_subnet`).
- Severity: `info`.
- Evidence: the service name where macOS gives one.
- Recommendation: none — it reframes the rest of the report.

**This one is about trust, not diagnosis.** The speed test runs *by
default* and moves hundreds of megabytes. On a phone's hotspot that is
the user's cellular allowance, spent by a tool they ran to ask a
question, without being asked. So `MET-1` comes with a **behaviour
change**: `speedtest_run` skips on a metered link unless `--speed` was
passed explicitly, and says so rather than skipping silently.

The GUI makes the stakes sharper: its one automatic full check fires on
joining a new network, and joining a phone's hotspot is exactly that
event. The guard lives in the CLI, which the app shells out to, so it
covers that path too.

`MET-1` itself fires whether or not the speed test was skipped, because
every *other* recommendation in the report changes on a tethered link.
"Reboot your router" and "check the cable" are nonsense when the router
is a phone in someone's pocket.

**Detection, and what it cannot see.** USB and Bluetooth tethering
announce themselves in the service name and are exact — this developer's
own service order lists `iPhone USB`. A phone's *Wi-Fi* hotspot is an
ordinary Wi-Fi network as far as every command-line tool netdiag can
reach: nothing in `scutil --nwi`, `ipconfig getsummary` or
`system_profiler SPAirPortDataType` reports it as expensive. (The
`expensive` and `constrained` flags do exist in `NWPathMonitor`, but are
not exposed to any CLI.) So that case falls back to the documented
default subnets — `172.20.10.0/28` for iOS, `192.168.43.0/24` for
Android — which is a heuristic and knowingly so: it misses a
reconfigured hotspot, and a home network using `192.168.43.0/24` would
match.

That asymmetry is deliberate for the *skip*. A false positive there
costs an unrequested test that is announced and overridable; a false
negative costs real money.

It is **not** acceptable for the *claim*, which is why `MET-1` has two
wordings and `LINK_METERED_CERTAIN` chooses between them. On the service
name it states the fact: "You're online through \"iPhone USB\"". On the
subnet inference it says what it saw and why it acted, and offers the
way out — because telling someone on a home LAN that happens to use
`192.168.43.0/24` that they are "online through a phone" would be a
confidently wrong claim about their own network, which is the exact
failure this whole family of work exists to remove.

### SP-1 — The wireless link is the speed cap

- Trigger: on Wi-Fi, `SPEEDTEST_DOWN_MBPS >= WIFI_TX ×
  THRESH_WIFI_GOODPUT_CEILING_PCT / 100`, via `pct_at_least`.
- Severity: `info`.
- Evidence: the measured download and the negotiated PHY rate.
- Recommendation: use ethernet, or move closer and prefer 5/6 GHz.

**The wrong conclusion it prevents.** "netdiag says 75 Mb/s, I pay for
500, my ISP is cheating me" — when the Wi-Fi link negotiated 130 Mb/s,
75 is the *most* that link can carry and no plan could deliver more
through it. Both numbers were already collected and nothing joined
them.

**Why a percentage rather than a margin.** Real TCP goodput over 802.11
is roughly half to two-thirds of the negotiated PHY rate and always well
under it — preamble, inter-frame spacing, ACKs and contention take the
rest. "Download ≈ PHY rate" never happens on a healthy link, so waiting
for it would mean the rule never fires.

`THRESH_WIFI_GOODPUT_CEILING_PCT` is 45, deliberately *below* that
50–65% band rather than inside it, because the expensive mistake is a
false positive: telling a user their Wi-Fi is the bottleneck when their
ISP is genuinely slow sends them to buy a router they do not need. A
50 Mb/s plan over a 130 Mb/s link is 38% and stays quiet; a gigabit plan
over the same link measures ~75 Mb/s, or 58%, and fires.

**Needs sudo.** `WIFI_TX` is one of the privileged Wi-Fi fields, so on
an unprivileged run this rule cannot fire at all. That is deliberate —
an explanation offered on a guess is worse than no explanation.

### ETH-1 — Ethernet negotiated below the port's capability

- Trigger: `LINK_MEDIA_MBPS < LINK_MEDIA_MAX_MBPS`, both parsed from
  `ifconfig -m <dev>` by `lib/linkstate.sh`.
- Severity: `warn`.
- Evidence: the negotiated rate and the port's advertised maximum.
- Recommendation: swap the cable; bypass any dock or hub.

No threshold. This compares two measured values, so on a genuinely
100 Mb/s-only adapter — where the negotiated rate *is* the maximum — it
stays quiet, because there the number is simply the truth.

**Why it matters.** A damaged pair in a cable, or a cheap dock, drops a
1000BASE-T link to 100BASE-TX. It is a 10× cap invisible everywhere in
netdiag except this one line of `ifconfig`, and the speed test then
reports ~94 Mb/s — so the user calls their ISP about a gigabit plan that
is being delivered correctly.

### ETH-2 — Ethernet stuck on half duplex

- Trigger: `LINK_DUPLEX == "half"` **and** the port's `supported media:`
  block advertises a full-duplex mode
  (`linkstate_media_has_full_duplex`).
- Severity: `critical`.
- Evidence: the negotiated media string.
- Recommendation: set both ends back to automatic rather than a pinned
  speed; swap the cable if that does not take.

The full-duplex-capability check is what makes this a fault rather than
an observation: a link running half duplex on a port that can do full
duplex is a *failed negotiation*, while a port that only ever does half
duplex is simply old and saying so would be noise.

**It also corrects `G2` and `G3`.** Collisions on a half-duplex link
produce heavy gateway packet loss, which `G2` otherwise reports with the
headline advice "reboot the router" — sending the user to power-cycle a
box that is working perfectly. When `ETH-2` has fired, `G2` and `G3`
state the loss and point at the negotiation instead of offering a
second, contradictory fix.

### DH-3 — Self-assigned address, DHCP never answered

- Trigger: no default route, `LINK_SELF_ASSIGNED == 1` — the active
  device's only IPv4 address is in `169.254.0.0/16`. Set by
  `lib/linkstate.sh::linkstate_run` via `linkstate_is_link_local`.
- Severity: `critical`.
- Evidence: the interface, the SSID where there is one, and the
  self-assigned address itself.
- Recommendation: rejoin the network (or replug the cable) so the Mac
  asks again; restart the router if that does not take.

**Why this is its own rule.** macOS assigns a `169.254` address when it
asks a network for one and nothing answers. It is the OS reporting the
*absence* of a lease — but it arrives on the same `ifconfig` `inet` line
as a real one, so `linkstate_parse_ifconfig_ip` returned it and
`linkstate_run` set `LINK_UP=1` and stopped searching. A total DHCP
failure was therefore recorded as a healthy, configured link.

It sits between the two rules it used to be confused with, and is a
third thing from both:

| | link | address | route |
|---|---|---|---|
| `N1` | none | — | — |
| **`DH-3`** | **yes** | **self-assigned** | **none** |
| `N1c` | yes | real lease | none |

Before this rule existed the case fell through to `N1`, which told a
user sitting on Wi-Fi at full signal that their Mac "has no network
connection at all — nothing is joined". The cause and the fix are both
entirely different from `N1`'s, so the wrong rule sent them to check a
cable that was fine.

`linkstate_run` also stopped preferring the *last* active device over
the first when nothing is configured; with self-assigned addresses now
reaching that path, the service order's ranking is what decides, since
it is macOS's own statement of which link the user thinks they are on.

## Rules added in v0.3.0 — NAT / WAN topology

### WAN-1 — Outbound traffic load-balanced across multiple ISPs

- Trigger: 3 parallel probes to `ifconfig.co/json` return more than one
  distinct `asn_org`. Emitted by `lib/wan.sh::wan_load_balancing_run`.
- Severity: `warn`.
- Evidence: list of distinct ASNs and IPs observed.
- Recommendation: often intentional (multi-WAN router, mwan3, etc.) —
  it just explains the IP-rebinding TLS warnings and asymmetric-routing
  surprises that some apps complain about.
- Rationale: outgoing connections from the same Mac to the same
  destination can land on different egress paths, breaking sticky
  session assumptions in some services.

### WAN-1b — Same ISP, multiple public IPs (CGNAT round-robin)

- Trigger: 3 probes return one ASN but more than one IP.
- Severity: `info`.
- Evidence: ASN and the distinct IPs.
- Recommendation: usually carrier-grade NAT round-robin; nothing the
  user can fix locally. Worth flagging if a service complains about
  "your IP keeps changing."

### NAT-1 — Double-NAT detected

- Trigger: traceroute path has > 1 consecutive RFC1918 hops before the
  first CGNAT (`100.64/10`) or public address. Emitted by
  `lib/wan.sh::wan_double_nat_run` (pure parse over `TRACE_LINES`).
- Severity: `warn`.
- Evidence: the RFC1918 chain printed in order.
- Recommendation: if you control multiple routers in the chain, put
  the inner one(s) in bridge/AP mode. UPnP and per-app port forwarding
  generally don't survive a double-NAT path.
- Caveat: ISPs sometimes use `10/8` for their internal transit, so a
  detected "chain" may include hops you can't influence. The diagnosis
  text prints the full chain so the user can identify which hops are
  in their own house vs the ISP's network.

### UP-1 — UPnP / NAT-PMP is enabled

- Trigger: probe to the gateway via `upnpc -s` (Homebrew `miniupnpc`),
  raw SSDP M-SEARCH on `239.255.255.250:1900`, or NAT-PMP on
  `gateway:5351` returned a response.
- Severity: `info`.
- Evidence: which probe succeeded (`miniupnpc` / `ssdp` / `nat-pmp`)
  and the IGD URL when known.
- Recommendation: disabled-UPnP is the safer default; enabled means
  apps can open ports without asking. If you don't run games / Plex /
  Steam / consoles that need it, you can disable it in the router UI.
- Rationale: defensive call-out, not a fault — most home networks have
  UPnP on by default and the user may not realise.
- **Not emitted as a diagnosis.** UPnP state already has its own row on
  the Report card, and `wan_diagnosis_run` deliberately skips re-stating
  it so the same fact isn't reported in two places. The ID is reserved
  and documented; nothing calls `add_diag` with it.

### NAT-1b — ISP-side private transit (not your double-NAT)

- Trigger: `wan.double_nat.isp_transit_count > 1` while home-side
  double-NAT was *not* detected.
- Severity: `info`.
- Evidence: the `10/8` transit chain from the traceroute.
- Recommendation: none — this is the carrier's normal internal routing.
- Rationale: carrier-grade NAT puts RFC1918 hops in a traceroute that
  look identical to a home double-NAT. Splitting them (see
  `_wan_split_nat_chain`) stops netdiag telling users to bridge a router
  they don't own. Only the home-side chain produces the actionable NAT-1.

## Rules added in v0.4.x–v0.5.x

### N1b — Router present, nothing public responds

- Trigger: `PUBLIC_CHECKED == 1` and `public.ok == 0` and gateway loss was
  never measured (a focused run such as `--mtu-only`).
- Severity: `critical`.
- Evidence: names the focus flag actually in use.
- Recommendation: re-run plain `netdiag` for a full picture.
- Rationale: focused runs skip the gateway section, so P1/P2 can't
  evaluate and a real outage would otherwise produce no diagnosis at all.
  `PUBLIC_CHECKED` is what keeps it honest — `--wifi-only` never runs
  `public_run`, and before v0.5.1 the untouched `PUBLIC_OK=0` default made
  this critical fire, and exit 2, on networks whose internet was fine.

### DI-2 — Duplicate IP on the LAN

- Trigger: an IP in `arp -an` resolving to more than one MAC.
- Severity: `critical`.
- Evidence: the colliding IP list.
- Recommendation: two devices are fighting over one address and will
  randomly steal each other's traffic. Usually a static IP colliding with
  the DHCP pool, or a second DHCP server. Find and renumber one of them.
- Rationale: split from DI-1 so "the router is unreachable at layer 2"
  and "two devices share an address" don't share a message. They have
  different causes and different fixes.

### BL-1 — A metric regressed against this network's own history

- Trigger: `baseline.regressions` is non-empty, which needs ≥ 3 prior runs
  recorded on the same `network.id`.
- Severity: `warn`.
- Evidence: metric name, current value, and the median it's compared to.
- Recommendation: depends on the metric; the text names what moved.
- Rationale: the point of the rolling baseline. An absolute threshold
  can't catch "your gateway RTT is 4× what it normally is" when the
  absolute number still looks fine. Scoped per-network since v0.5.0 —
  before that, a laptop moving between home and a café reported a
  regression on every move.
- Speedtest confirmation: a speed test result depends on who else is using
  the link at that exact moment as much as on the network's own health, so
  `speedtest.down_mbps` / `speedtest.up_mbps` need more than one bad
  reading before they raise BL-1. A drop is only reported once the current
  run **and** the `THRESH_SPEED_CONFIRM_RUNS - 1` measured runs immediately
  before it (1 run, with the default of 2) are all below
  `THRESH_SPEED_DROP_FACTOR` (0.5) × the median — both in
  `lib/thresholds.sh`, read by `helpers/baseline.py` through the
  environment the same way `helpers/history.py` reads `THRESH_COMPARE_*`.
  One slow run while someone else streams is not a regression; two in a row
  is. Every other metric in `helpers/baseline.py`'s table (gateway RTT,
  bufferbloat delta, path MTU, ISP) keeps firing on a single measured run —
  only the speed metrics need confirmation.

## Rules emitted only by `--monitor`

`--monitor` evaluates a deliberately partial mirror of the rules above —
see the comment at the top of `lib/monitor.sh::_mon_rules` — on whichever
inputs a between-scans sample actually has.

### CP-1 — Captive portal blocking real access

- **Trigger:** the probe to `http://captive.apple.com/hotspot-detect.html`
  comes back intercepted rather than answered — a redirect (3xx), a 511
  Network Authentication Required, or a 200 whose body is not Apple's
  literal success page. Classified by `captive_portal_classify` in
  `lib/common.sh`, shared by `lib/public.sh::public_run` (scan) and
  `lib/monitor.sh::_mon_probe_public` (monitor).
- **Severity:** critical when `public.ok` is false — nothing is getting
  through and the network is unusable until the portal is accepted. Warn
  when traffic is still flowing and the portal is merely waiting to cut
  it off.
- **Evidence:** the observed HTTP status.
- **Recommendation:** open a browser and complete the portal's login or
  terms page.
- **Precedence: CP-1 suppresses P1 and P2**, in the scanner and in the
  monitor alike. Both are guarded on `CAPTIVE_PORTAL` / `MON_CAPTIVE`.

**Correcting the record.** This section previously argued that CP-1 was
monitor-only by design, because "a full scan runs the exact same probe
but doesn't need a rule for it: a detected portal already surfaces as
`public.captive_portal` in the JSON and a warn line in the Public
reachability section, and when the portal is actually blocking traffic
the `ifconfig.co` fetch fails too, so P1/P2 fire anyway."

That was wrong on both counts, and the stored run
`2026-08-26T22:53:05Z` shows how:

- A field in the JSON and a line in a section are not a diagnosis.
  `status.rules[]` is what feeds `status.severity`, the exit code, the
  GUI's "What we found" panel and the menu-bar dot. A portal reached none
  of them.
- "P1/P2 fire anyway" is the defect, not the mitigation. P1 says *"almost
  certainly an outage on your ISP's side — check their status page or
  call support."* On a hotel network that is not merely unhelpful, it
  sends the user to phone a company whose service is working, and buries
  the one action that would have fixed it in thirty seconds.

The probe was also weaker than this section implied: it classified on the
HTTP status alone with `curl -o /dev/null`, so a portal answering 200 with
its own login page — the common case — was reported as "No captive
portal." See `captive_portal_classify`.

## Rules under active development

The internet-side loss family (`G3`, `L1`, `L2`, `ICMP-1`) is being
implemented separately; see `tests/test_loss.bats` and the
`LOSS_WARN_PCT` / `LOSS_CRIT_PCT` thresholds in `lib/globals.sh`. This
file will be updated when that work lands.
