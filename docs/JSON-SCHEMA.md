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
| `internet_latency` | object | same shape against `1.1.1.1` |
| `public` | object | `ip`, `asn`, `isp`, `city`, `country`, `captive_portal` |
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
