# netdiag `--json` schema

`netdiag --json` writes exactly one JSON object to stdout and nothing else,
so `netdiag --json | jq .` is always safe. Colors are disabled and no log
file is written unless `--log PATH` is also passed.

This document describes what `helpers/emit_json.py` actually emits, which
is the authoritative definition. A machine-readable sample from a real run
is in [`../examples/sample-output.json`](../examples/sample-output.json).

## Conventions

- **`null`** means the check did not run — skipped by `--quick`, gated
  behind `sudo`, missing an optional dependency, or not applicable to this
  network. It never means "ran and found nothing".
- **`[]`** means the check ran and found nothing. `duplicate_ips: []` is a
  clean ARP table; `duplicate_ips: null` would mean the scan never ran.
  This distinction is the whole point — treating "not measured" as "zero"
  is what produced false diagnoses in earlier versions.
- Every top-level key is always present, even when its value is `null`.
- Durations are seconds, latencies are milliseconds, both as floats.
- Percentages are numbers, not strings: `0.0`, not `"0%"`.

## Top-level keys

| Key | Type | Notes |
|-----|------|-------|
| `version` | string | netdiag version that produced this run |
| `timestamp` | string | ISO 8601, UTC |
| `interface` | object | active interface, IP, gateway, gateway MAC, `type` (`wifi`/`wired`) |
| `network` | object | `id` + human `label` identifying which network this is — scopes the baseline |
| `wifi` | object | SSID, BSSID, security; `rssi`/`noise`/`snr`/`channel`/`phy`/`tx_rate` are `null` without `sudo` |
| `gateway` | object | `ip`, `loss_pct`, `rtt_avg_ms`, `rtt_jitter_ms` |
| `internet_latency` | object | `target`, `rtt_avg_ms`, `rtt_jitter_ms`, `loss_pct` against the primary public target, plus `target_alt`, `rtt_avg_ms_alt`, `loss_pct_alt` for the second, independent one. The L1 packet-loss rule escalates to critical only when **both** targets exceed the threshold, so a consumer reproducing the diagnosis needs both numbers. Any field is `null` when that probe didn't run (`--quick`) or returned no summary — never `0`, and never `100`. |
| `public` | object | `ip`, `asn`, `isp`, `city`, `country`, `country_iso`, `captive_portal`. `country` is the full name (`"Brazil"`); `country_iso` is the ISO-3166 alpha-2 (`"BR"`). Both are emitted because they answer different questions — the name is what a report should read, the code is what a consumer maps to a flag or a locale — and deriving one from the other would mean shipping a country table in every consumer. |
| `dns` | array | one entry per resolver × name: `resolver`, `name`, `answer`, `ok` |
| `traceroute` | object | `target` + `hops[]` (`n`, `ip`, `responded`, `rtt_ms`) |
| `per_hop` | array | per-hop loss probe: `n`, `ip`, `responded`, `loss_pct`, `avg_ms` |
| `bufferbloat` | object | idle/loaded RTT for gateway and internet, their deltas, and `gw_grade`/`inet_grade` (A–F) |
| `mtu` | object | `effective` (payload + 28) and the `path_size` payload that passed |
| `ipv6` | object | `available`, `global_addr`, `gateway`, `ping_loss_pct`, `aaaa_ok`, `trace_hops`, `tcp_v6_ok` |
| `vpn` | object | `active`, `type` (`managed`/`tailscale`/`utun-route`), `name` |
| `tcp_reach` | array | `host`, `port`, `ok`, `elapsed_ms` |
| `wifi_scan` | object | `current_channel`, `current_band`, `neighbour_count`, `current_channel_neighbours` |
| `wifi_disconnects` | object | `window_hours`, `count` |
| `speedtest` | object | `null` unless `--speed` was passed |
| `ntp` | object | `drift_seconds`, `using_network_time`, `server` |
| `duplicate_ips` | array | IPs seen with more than one MAC in the ARP table |
| `dhcp` | object | lease detail; see the `dns_servers` note below |
| `mtr` | object | `target`, `duration_s`, `hops[]`, `first_lossy_hop` |
| `wan` | object | `load_balancing`, `double_nat`, `upnp` — see below |
| `hosts_file` | object | `custom_count`, `suspicious_redirects[]` |
| `timings` | object | `total_s`, `budget_s`, `over_budget`, and `phases{}` per stage |
| `baseline` | object | comparison against history, or `null` — see below |
| `diagnosis` | array | `severity` (`info`/`warn`/`critical`), `rule`, `summary` |
| `most_likely_root_cause` | string | the highest-severity diagnosis summary, first by insertion order |
| `netdiag_extras` | object | `arp_gw_incomplete`, plus `target*` keys when a positional TARGET was given |

## `wan`

```json
{
  "load_balancing": {"distinct_asns": ["AS1234"], "distinct_ips": ["..."], "active": false},
  "double_nat": {
    "detected": false,
    "rfc1918_chain": ["192.168.15.1"],
    "home_chain": ["192.168.15.1"], "home_count": 1,
    "isp_transit_chain": [], "isp_transit_count": 0
  },
  "upnp": {"state": "disabled", "device": null, "url": null, "tested_via": "ssdp"}
}
```

`detected` means *home-side* double-NAT only. ISP-side private transit
(carrier-grade NAT) lands in `isp_transit_chain` instead, because it is
normal for the carrier and not something the user can fix.

## `baseline`

`null` when `--no-baseline`/`--quick` was used, or when fewer than three
prior runs exist **on this same network**. Runs are matched by
`network.id` — gateway MAC, then SSID, then gateway IP — so a laptop
moving between home and a café doesn't compare the two.

```json
{
  "compared_runs": 12,
  "network_id": "gwmac:aa:bb:cc:dd:ee:ff",
  "skipped_other_networks": 40,
  "regressions": [
    {"metric": "gateway.rtt_avg_ms", "current": 12.3, "median": 3.5,
     "label": "gateway RTT", "kind": "spike"}
  ]
}
```

`kind` is one of `spike` (higher-is-worse metric above median × factor),
`drop` (higher-is-better metric below median × factor), or `drift` (an
absolute value like PMTU, ISP, or WiFi channel simply changed).

## Known wart

`dhcp.dns_servers` is a **space-separated string**, not an array, despite
the plural name and despite the original spec calling for an array.
Changing it would break any consumer already parsing it, so it is
documented rather than silently altered. Split on whitespace:

```sh
netdiag --json | jq -r '.dhcp.dns_servers | split(" ")'
```

## `--redact`

`--redact --json` masks public IP, SSID, BSSID, IPv6 global address,
gateway MAC and city in the emitted object. ASN, ISP name and RFC1918
addresses are deliberately kept — they identify a provider or a private
range, not a person, and removing them would gut the NAT and ARP data.
See the README's "Sharing a report" section.

## Exit codes

The JSON object does not carry the exit code; read it from the process.
`0` healthy, `1` warnings only, `2` at least one critical diagnosis,
`3` script error (bad flag, missing bash 5, unexpected abort).

---

# `netdiag --monitor` sample schema

A **separate, smaller shape** from a full run — not a subset of it by
accident. A run answers *"what is wrong and why"* and costs 30–115 s; a
monitor sample answers *"what is true right now"* and costs a couple of
seconds. Mixing them would mean either a stream too expensive to emit
every ten seconds or a report too thin to diagnose from.

`netdiag --monitor` writes **one JSON object per line** on stdout, flushed
per sample, until stopped. No log file, no `baseline.jsonl` append,
nothing under `~/net-diag` — it runs for days, and anything it accumulated
it would accumulate forever.

```jsonc
{
  "schema": 1,
  "version": "0.7.0",
  "ts": "2026-08-11T16:20:51Z",
  "seq": 42,
  "refreshed": ["fast"],          // which cadence tiers ran this cycle
  "link":    {"up": true, "interface": "en0", "type": "wifi", "ip": "…",
              "gateway": "192.168.15.1", "gateway_mac": "10:98:5f:…",
              "ssid": null, "bssid": null},
  "network": {"id": "wifi:mac=10:98:5f:…", "label": "…"},
  "vpn":     {"active": false, "type": null, "name": null},
  "gateway": {"loss_pct": 0.0, "rtt_avg_ms": 4.1},
  "wifi":    {"rssi": null, "noise": null, "snr": null, "channel": null},
  "dns":     {"ok": true, "resolver": "192.168.15.1", "elapsed_ms": 12},
  "tcp":     {"any_ok": true, "targets": [{"host": "1.1.1.1", "port": 443,
                                           "ok": true, "elapsed_ms": 30}]},
  "public":  {"ok": true, "ip": "…", "isp": "…", "asn": "AS10429",
              "city": "…", "country": "Brazil", "country_iso": "BR",
              "captive_portal": false},
  "status":  {"severity": "ok", "rules": [], "icmp_filtered": false,
              "degraded": false, "paused": false, "cadence_s": 10}
}
```

## Conventions specific to the stream

- **`refreshed`** lists the tiers that actually ran this cycle. Everything
  outside it is carried over from an earlier sample. A consumer plotting a
  series needs this: `public.ip` is refreshed every 300 s, so nine out of
  ten samples repeat the previous value rather than re-measuring it.
- **`null` still means "not measured"**, and here it also covers "that
  tier was not due this cycle". `dns.ok` is `null` until the medium tier
  first runs — it is emphatically not `false`, which would mean the query
  was made and failed.
- **`status.rules`** are rule IDs from
  [`DIAGNOSIS-RULES.md`](./DIAGNOSIS-RULES.md), evaluated in
  `lib/monitor.sh` against the same `lib/thresholds.sh` constants that
  `lib/diagnosis.sh` reads. For any given network state the monitor and a
  full run name the **same** rule IDs; the bats suite asserts that parity
  over eleven conditions. Consumers render this list. They must not
  re-derive it, or the app can contradict the report it links to.
- **`status.icmp_filtered`** is TCP-1 holding: real connections work,
  only ping is being dropped. Common on hotel and corporate networks.
  The loss rules still fire — withholding them would break parity with a
  scan — so this flag is what an alert engine reads to suppress a loss
  notification that would always be wrong.
- **`status.paused`** means `SIGUSR1` suspended probing. Every measurement
  in such a sample is stale by definition; do not plot or alert on it.

## Tiers and cadence

| Tier | Probes | Default | Flag |
|---|---|---|---|
| fast | gateway ping ×10, VPN state, link/SSID, identity | 10 s (5 s when degraded) | `--monitor-fast-interval`, `--monitor-degraded-interval` |
| medium | DNS resolve, TCP/443 ×2, RSSI/SNR | 60 s | `--monitor-medium-interval` |
| slow | public IP, ISP, ASN, country, captive portal | 300 s, **plus immediately on network change** | `--monitor-slow-interval` |

The slow tier is the only one making an external call, which is why it is
slow and why a network change overrides its timer — that is exactly when
its answer has certainly gone stale.

The gateway probe sends **ten** packets rather than the three a liveness
check suggests, for quantisation rather than accuracy: at 3 packets the
only reportable losses are 0/33/67/100 %, so a single dropped packet reads
as 33 % — past the 20 % critical floor. At 10 the quantum is 10 %, so one
drop lands in G3's warn band and it takes two to reach critical, the same
shape the scanner's 20-packet probe produces.

## Signals

| Signal | Effect |
|---|---|
| `SIGUSR1` | pause — stop probing, stay alive, emit one `status.paused` sample |
| `SIGUSR2` | resume |
| `SIGTERM` / `SIGINT` | exit cleanly (immediately, even mid-probe) |

Pausing is handled **in-process** rather than by the caller sending
`SIGSTOP`, and that is a correctness requirement, not a preference. POSIX
delivers `SIGHUP` followed by `SIGCONT` to a process group that becomes
newly orphaned while any member is stopped. A `SIGSTOP`ped monitor still
has live children — the two-second gateway ping, `with_timeout`'s killer
subshells — so the moment one exits, the group orphans and the `SIGHUP`
kills it. Measured under a GUI parent: the monitor died 2.1 s into every
pause, exactly one ping probe. It never reproduced from a terminal,
because a controlling terminal keeps the group non-orphaned.

## `--monitor` vs `--watch`

They are not two of the same thing:

| | `--watch[=SEC]` | `--monitor` |
|---|---|---|
| Audience | a person watching a terminal | a program |
| Output | prose, the Diagnosis section per iteration | one JSON object per line |
| Work per cycle | a full `--quick` run (~10 s) | one tier's probes (~2 s) |
| Writes | a log file and a `baseline.jsonl` record per run | nothing |
| Cadence | one interval | three tiers, adaptive |

Use `--watch` to sit and watch a flaky link. Use `--monitor` to feed
something.

---

# `netdiag --history` schema

`netdiag --history` emits one object collapsing the whole run store —
`~/net-diag/baseline.jsonl` plus its `-archive.jsonl` sibling — into
network-grouped rows a chart can decode cheaply. On the author's machine
that is 5.4 MB of full snapshots reduced to 467 KB.

```jsonc
{
  "schema": 1,
  "sources": {"live": "…/baseline.jsonl", "archive": "…/baseline-archive.jsonl"},
  "counts":  {"records_read": 1972, "unparseable_dropped": 0,
              "duplicates_dropped": 0, "redacted_dropped": 11,
              "runs": 1961, "networks": 4},
  "metrics": [{"key": "gateway_rtt_ms", "label": "Gateway RTT", "unit": "ms",
               "direction": "lower_is_better", "samples": 1959}],
  "networks": [{"id": "mac:10:98:5f:…", "label": "…", "synthesized": false,
                "bridged_from": [], "first_seen": "…", "last_seen": "…",
                "run_count": 35, "gateways": [], "isps": [], "ssids": [],
                "metric_samples": {}, "severity_counts": {}}],
  "runs": [{"ts": "…", "network_id": "mac:10:98:5f:…", "version": "0.6.1",
            "severity": "warn", "diagnosis_count": 1, "rules": ["M1"],
            "root_cause": "…", "metrics": {"gateway_rtt_ms": 3.4}}]
}
```

- **Grouping is not exact-string matching on `network.id`.** Records
  predating `lib/netid.sh` carry no id at all, and the id of the *same*
  network changes the day Location Services is granted (`wifi:mac=X`
  becomes `wifi:ssid=Y,mac=X`). Groups key on the `mac=` component where
  present, backfill idless records through `netid.sh`'s own precedence,
  and bridge weak groups into MAC groups only when gateway **and** ISP
  agree. See the module docstring in `helpers/history.py`.
- **`synthesized: true`** means the grouping was inferred — backfilled,
  bridged, or merged by hand in the app — rather than recorded. The UI
  says so rather than implying a certainty it does not have.
- **`metrics[].samples`** is not decoration. Sparse series are the normal
  case: in the store this was written against, `gateway_rtt_ms` has 1,959
  samples and `wifi.rssi` has 1. A chart that omits the count presents a
  single reading as a trend.
- **A run's `metrics` omits what was not measured.** Absent, never zero —
  the same distinction the full schema draws, and for the same reason.
- **Redacted records are dropped and counted.** A run recorded with
  `--redact` has `network.id = "wifi:mac=[redacted]"`, shared with every
  other redacted run on every other network, so it can never join a real
  group. (`lib/output.sh` stopped producing them in v0.7.0; these are the
  historical ones.)
