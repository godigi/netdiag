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

**Fires when:** `GATEWAY` is empty (no default route).

**Severity:** critical.

Every other rule keys off a measurement that only exists once there is a
link — gateway loss, public reachability, DNS answers. Before this rule
existed, a Mac with WiFi switched off produced *zero* diagnoses and
exited 0 with "Nothing obviously wrong — your network looks healthy",
because each rule's guard (`[ -n "$GW_LOSS" ]` and friends) short-circuited
on the missing data. N1 is the floor: it fires first, states the obvious,
and makes the exit code 2.

A second, narrower branch covers focused runs: `--mtu-only` skips the
gateway section, so `PUBLIC_OK=0` with an empty `GW_LOSS` can't reach P1
or P2. That branch points the user at a full run rather than guessing.

### W1 — Weak WiFi signal

- Trigger: `wifi.rssi < -75`
- Severity: `warn`
- Recommendation: move closer to the AP, or switch bands/AP.

### W2 — Low WiFi SNR

- Trigger: `wifi.snr < 20 dB`
- Severity: `warn`
- Recommendation: change channel — interference on the current one.

### G1 — Gateway loss + weak WiFi

- Trigger: `gateway.loss_pct >= 20 AND wifi.rssi < -70`
- Severity: `critical`
- Recommendation: WiFi link is the problem, not the router or ISP.

### G2 — Gateway loss with healthy WiFi

- Trigger: `gateway.loss_pct >= 20 AND NOT W1`
- Severity: `critical`
- Recommendation: router itself is misbehaving — reboot it.

### P1 — DNS down, public unreachable

- Trigger: `public.ok == false AND gateway.loss_pct == 0 AND dns.ok == false`
- Severity: `critical`
- Recommendation: DNS or upstream ISP outage.

### P2 — Public unreachable, DNS up

- Trigger: `public.ok == false AND gateway.loss_pct == 0 AND dns.ok == true`
- Severity: `critical`
- Recommendation: ISP-side outage.

### D1 — Partial DNS, internet reachable

- Trigger: `dns.ok == false AND public.ok == true`
- Severity: `warn`
- Recommendation: change resolver (1.1.1.1 or 8.8.8.8).

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
### VPN-1 — VPN is carrying the default route

- Trigger: `vpn.active == true` (any of: scutil --nc shows Connected,
  tailscale status BackendState==Running, default route via utun*/wg*).
- Severity: `info` (it's a heads-up, not a fault).
- Evidence: VPN type and name.
- Recommendation: the "gateway" line is the VPN endpoint, not your LAN
  router. RTT, loss, and traceroute reflect the tunnel — for a true
  picture of the local link, disconnect the VPN and run netdiag again.
- **Status: specified but not yet emitted.** `lib/vpn.sh` prints a section
  line and stops there — no `add_diag` call exists, so an active VPN does
  not currently reach the Diagnosis section even though this file and the
  README have both promised it since v0.1.0. The implementation is written
  and tested and lands with the next release; this note goes away with it.
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
- Severity: `critical`.
- Evidence: drift in seconds from `sntp -t 3 time.apple.com`.
- Recommendation: re-enable network time (System Settings → General →
  Date & Time → Set automatically).
- Rationale: TLS validates cert NotBefore/NotAfter against the system
  clock. > 30 s drift starts breaking handshakes on certs near their
  rotation window; days of drift breaks everything. Users see this as
  "nothing loads" without any network-level fault to blame.
- **BL-1** — Metric regression vs 30-day median (gateway RTT, RSSI, PMTU, etc.).
### DI-1 — Duplicate IPs or incomplete gateway ARP

- Trigger: any IP in `arp -an` with > 1 distinct MAC, or the gateway IP
  marked `(incomplete)`.
- Severity: `critical`.
- Evidence: duplicate IP list, or `(IP) at (incomplete)` line for the
  gateway.
- Recommendation: a duplicate IP means another LAN device is squatting
  the address (static-IP collision or rogue DHCP server). Incomplete
  gateway = L2 to the router is broken (cable, AP, switch port).
- Rationale: nothing above this in the stack matters if ARP can't
  resolve. Surface it early.

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

## Rules under active development

The internet-side loss family (`G3`, `L1`, `L2`, `ICMP-1`) is being
implemented separately; see `tests/test_loss.bats` and the
`LOSS_WARN_PCT` / `LOSS_CRIT_PCT` thresholds in `lib/globals.sh`. This
file will be updated when that work lands.
