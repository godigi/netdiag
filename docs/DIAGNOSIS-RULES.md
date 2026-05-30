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

- **MT1** — First lossy hop identified via `mtr` → blame the hop *before* it.
- **V6-1** — v6 broken with v4 healthy → router/ISP v6 misconfig (Happy Eyeballs masks).
- **VPN-1** — VPN active → "gateway" below is the VPN endpoint, not your LAN router.
- **TCP-1** — TCP/443 works but ICMP fails → ICMP filtered; ignore ping-based negatives.
- **WS-1** — Channel congestion → too many neighbouring APs on the same channel.
- **WD-1** — WiFi link flapping → > 3 disconnects/hour.
- **ST-1** — Speed regression vs baseline.
- **NT-1** — System clock drift > 30 s → TLS failures everywhere.
- **BL-1** — Metric regression vs 30-day median (gateway RTT, RSSI, PMTU, etc.).
- **DI-1** — Duplicate IPs in ARP table or `(incomplete)` gateway entry.
- **DH-1** — DHCP lease expires within 1 hour.
- **DH-2** — DHCP-handed DNS differs from system resolver — user override.
