# Diagnosis rules

> Every rule the diagnosis engine emits is documented here with: what it
> triggers on, what evidence it cites, what severity it carries, and the
> rationale. Rules are ranked by severity × confidence; the highest-ranked
> rule is surfaced as `most_likely_root_cause` in the JSON output.

## Severity

- `critical` — the network is unusable or about to be.
- `warn` — performance is degraded or a known foot-gun is active.
- `info` — surfaced for context, not actionable on its own.

## Rules in the v0.1.0 starter

The original script emits the rules below. Replacing them with the ranked
engine is a future step; for now they're listed verbatim for traceability.

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

## Rules to add (one per upcoming feature)

These are placeholders; each will be filled in when its source feature lands.

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
- Recommendation: the "gateway" line below is the VPN endpoint, not your
  LAN router. RTT, loss, and traceroute reflect the tunnel — for a true
  picture of the local link, drop the VPN or run with --no-vpn-bypass
  (future flag).
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
- **NT-1** — System clock drift > 30 s → TLS failures everywhere.
- **BL-1** — Metric regression vs 30-day median (gateway RTT, RSSI, PMTU, etc.).
- **DI-1** — Duplicate IPs in ARP table or `(incomplete)` gateway entry.
- **DH-1** — DHCP lease expires within 1 hour.
- **DH-2** — DHCP-handed DNS differs from system resolver — user override.
