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
| `run_mode` | string | how much of the battery this run attempted — see below |
| `run_id` | string \| null | the id `netdiag --history`/`--show` will use for this same run — see below |
| `interface` | object | `name`, `ip`, `gateway`, `gateway_mac`, `type` (`wifi`/`wired`), `link_status`, `link_up`, `dhcp_router`. `gateway` is the default route's gateway and is `null` when there is no default route. `link_status` is `ifconfig`'s own word (`"active"` / `"inactive"` / `null`) and `link_up` is `true` when an active device also holds an address — together they answer "is this Mac joined to anything", which is a *different question* from `gateway`, and conflating the two is what made `N1` tell users on hotel WiFi that their WiFi was off (see `DIAGNOSIS-RULES.md#n1c--joined-with-no-route-out`). `dhcp_router` is the router the DHCP server offered, present whether or not the kernel installed a route to it. `self_assigned_ip` is `true` when the only IPv4 address on the link is a `169.254.0.0/16` one macOS assigned itself because no DHCP server answered — a third state, not a flavour of `link_up`: `ip` is populated and `link_up` is `false`, which without this flag reads as a contradiction rather than as the DHCP failure it is (see `DIAGNOSIS-RULES.md#dh-3--self-assigned-address-dhcp-never-answered`). `link_mbps`, `link_max_mbps` and `duplex` describe the wired negotiation, from `ifconfig -m`: the rate the link settled on, the top rate the port advertises, and `"full"` / `"half"`. All three are `null` on Wi-Fi, which reports no media subtype at all. `link_mbps` below `link_max_mbps` is `ETH-1`; `duplex` of `"half"` on a port that advertises full duplex is `ETH-2`. |
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

## `run_mode`

Which shape of run produced this record. The CLI currently emits:

| value | flags | counts as a check? |
|---|---|---|
| `full` | none | yes |
| `quick` | `--quick` | yes |
| `speed-only` | `--speed-only` | no |
| `mtu-only` | `--mtu-only` | no |
| `wifi-only` | `--wifi-only` | no |
| `dns-only` | `--dns-only` | no |
| `bufferbloat-only` | `--bufferbloat-only` | no |
| `ping-only` | `--ping-only` | no |

Every record looked alike before v0.9.0, which is why "1,986 checks" on a
network overstated what had actually been measured: a `--quick` run skips
bufferbloat, mtr, the speed test, the loss probe and the WiFi scan, and a
focused run skips almost everything.

A **partial mode** — anything ending `-only` — contributes its measurements
and nothing else. `helpers/history.py` counts its metrics into
`metric_samples`, and excludes it from `check_count`, `counts.checks` and
`severity_counts`. A speed test is a measurement, not an opinion about the
network's health.

The suffix is the rule rather than a hand-maintained list, because every
focused mode comes from the same `FOCUS` mechanism and every `FOCUS` flag is
named `--<section>-only`. New focused modes therefore remain partial without
requiring a second history predicate.

**`null` on every record written before v0.9.0**, and absence decodes as
"unknown, treat as a check" — those runs were full or quick ones, and
reclassifying them would rewrite two months of history.

`--speed-only` is the one focused mode that *is* recorded. The other focused
modes write no history record, because their measurements are not comparable
to the full-check population.

## `run_id`

The same `"<timestamp>.<8 hex>"` id [`--history`](#netdiag---history-schema)
and `--show` (below) use to address this run, computed at run time rather
than waiting for a later `--history` call to derive it — a GUI reacting to
an alert needs to deep-link to "the check that just ran" immediately, not
after its next poll. `lib/output.sh` computes it by importing
`helpers/history.py`'s own `canonical()`/`run_id()` functions rather than
reimplementing them, from the exact record about to be appended, so the
value here and the one `--history` derives later can never disagree.

`null` in these cases. The first group is "no record was appended this run":

| case | why |
|---|---|
| `--no-baseline` | disables the append outright |
| `--mtu-only` | a focused run isn't comparable to a full one; unrecorded since before `run_id` existed |
| `--wifi-only` | same as `--mtu-only` |
| `--dns-only` | same as `--mtu-only` |
| `--bufferbloat-only` | same as `--mtu-only` |
| `--ping-only` | same as `--mtu-only` |

`--speed-only` is **not** in that list: it appends per v0.9.0, and gets a
real `run_id` like a `full` or `quick` run.

The fourth, `--redact`, is null for a different reason — see immediately
below.

**`--redact` is the exception that isn't about the append.** `lib/output.sh`
always writes the *private*, unredacted build to `baseline.jsonl` —
`build_json_private`'s whole reason for existing — so a `--redact` run
really does get stored, and really does have a derivable id. `run_id` is
`null` here anyway: it is a pointer back into that private copy, and a
report built to leave the machine should not carry a working key into data
it otherwise took pains to mask, even though that data never left this
machine. `emit_json.py`'s `redact()` nulls it explicitly, since it isn't
built from any of the values the ordinary secret-scrub catches.

**Never a key on the stored record itself.** The build that becomes the
appended `baseline.jsonl` line is produced *without* `run_id` ever set —
not even to `null` — specifically so the key can never be part of the
bytes `--history` hashes to compute that same id. A record with a `run_id`
key inside it would be hashing its own answer. Every top-level key in the
rest of this document is unconditionally present per the convention at the
top of this page; `run_id` is the one exception, and this paragraph is its
documentation.

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

# `netdiag --progress` event stream

`netdiag --progress` reports its own progress as it runs: one JSON object
per line, **on file descriptor 3**, which the CLI points at stderr. The
run's own output is unaffected — `--json --progress` still writes exactly
one object to stdout.

```console
$ netdiag --quick --progress 2>&1 >/dev/null | head -4
{"t":"plan","phases":["iface","vpn","wifi","gateway", …],"mode":"quick"}
{"t":"phase","name":"iface","state":"start"}
{"t":"phase","name":"iface","state":"done","rc":0,"ms":19}
{"t":"phase","name":"vpn","state":"start"}
```

## Why fd 3

Not stdout: acceptance criterion 2 is that `netdiag --json | jq .` always
succeeds, so stdout carries one object and nothing else.

Not stderr either, and this is the part that is not obvious.
`launch_parallel` runs each parallel check in a subshell that does
`exec 1>"$out" 2>&1`, capturing **both** streams into a per-check buffer. A
parallel check writing progress to stderr writes it into that file, where
nobody reads it until the check finishes — which is the exact moment
progress stops being worth having. fd 3 survives that redirect, so a check
announces its result the instant it lands.

fd 3 is opened for every run: at stderr under `--progress`, at `/dev/null`
without it. A consumer reads stderr and ignores lines that do not parse,
the same way it already tolerates noise on the `--monitor` stream.

## Events

| `t` | when | fields |
|---|---|---|
| `plan` | once, before the first phase | `phases[]` in attempt order, `mode` (the `run_mode` above) |
| `phase` … `start` | a check begins | `name` |
| `phase` … `done` | a check finishes | `name`, `rc` (the check's own exit status), `ms` (wall-clock, whole milliseconds) |
| `phase` … `skip` | a check declined to run | `name`, `why` (free text, clamped to 120 characters) |
| `speed` | sub-progress inside the speed test | `stage`, `progress`, `mbps`, `ms` — all nullable |
| `run` … `done` | last, always | `exit` (the process's exit code) |

```json
{"t":"plan","phases":["iface","vpn","wifi","gateway"],"mode":"full"}
{"t":"phase","name":"gateway","state":"start"}
{"t":"phase","name":"gateway","state":"done","rc":0,"ms":2043}
{"t":"phase","name":"wifi_scan","state":"skip","why":"not on wifi"}
{"t":"speed","stage":"download","progress":0.42,"mbps":180.3,"ms":null}
{"t":"run","state":"done","exit":1}
```

## A plan, not a percentage

`--json` produces nothing until the very end, so there is no quantity a
percentage could be a percentage *of*. The `plan` event names the phases
this mode will attempt and each resolves to `done` or `skip`, so "17 of 25,
testing under load" is true where a progress bar would not be.

`full` and `quick` declare the **same** phases. `--quick` does not skip a
call site — `bufferbloat_run`, `mtr_run` and the rest are invoked either
way and return early — so under `--quick` they report `skip` with
`why: "--quick"`. A phase that resolved as `done` in 0 ms would read as
"measured, instantly", which is the opposite of what happened.

The plan is a declared list, and a declared list drifts from the code the
first time a check is added. `tests/test_progress.bats` asserts both
directions: every name `bin/netdiag` passes to `run_timed` or
`launch_parallel` appears in some mode's plan, and every planned name is
one `bin/netdiag` actually runs.

## Lines stay short

Every event is emitted with a single `printf` of a line well under 512
bytes. Writes to a pipe are atomic only up to `PIPE_BUF` (512 on macOS) and
all the parallel subshells share this one fd, so an event assembled from
two writes could interleave with another check's and produce a line that
parses as neither. Free-text fields (`why`, `stage`) are clamped before
they are escaped — clamping afterwards can cut between a backslash and the
character it escapes.

## Speed-test sub-progress

Ookla's CLI streams, so `lib/speedtest.sh` runs it as
`speedtest --format=jsonl --progress=yes` and translates each update:

```
{"type":"ping","ping":{"jitter":0.0,"latency":27.942,"progress":0.200}}
  → {"t":"speed","stage":"ping","progress":0.200,"mbps":null,"ms":27.942}
```

`progress` is a fraction of that stage, not of the test. `mbps` is the
running throughput, `ms` the latency, and both are `null` in stages that do
not measure them — never `0`.

**Only `type`, `progress`, `bandwidth` and `latency` are forwarded.** This
is a security boundary, not tidiness: Ookla's first line is `testStart` and
it carries `interface.internalIp`, which on a dual-stack Mac is the
machine's **public IPv6 address** — a value that identifies a household the
way a NATed v4 address does not. `externalIp`, `macAddr` and the test
server's address are on the same line.

The translation is therefore deny-by-default. Four values are extracted by
name and a new object is built from them; nothing is passed through and
nothing is filtered out, because a filter has to enumerate what is
dangerous and is wrong the day Ookla adds a field. Both extractions are
shape-constrained as well: the numeric one matches `"key":<number>` only,
so a string can never satisfy it whatever it is named, and the stage
accepts only `[A-Za-z]`. `tests/test_progress.bats` feeds it a fixture
containing an `internalIp` and asserts nothing resembling it reaches fd 3.

Under `speedtest-cli` there is no stream. The stage is announced with **no
progress fraction** and the result arrives at the end; a UI shows an
indeterminate stage rather than inventing motion.

## Error handling

| case | behaviour |
|---|---|
| `--progress` with nobody reading | fd 3 goes to stderr like any other diagnostic output |
| `--progress` with stderr closed | the dup fails, writes fail silently, the run continues — progress must never be able to fail a check |
| a malformed line | consumers skip lines that do not parse, as on the `--monitor` stream |
| Ookla absent, `speedtest-cli` present | stage announced, no `progress` fraction, result at the end |
| neither present | the `speedtest` phase emits `skip`, `why: "no speedtest CLI installed"` |
| a planned phase that never reports | after the `run` event, treat it as "didn't run" rather than still running |
| `--progress` not passed | **nothing** is written to fd 3, and stderr is byte-for-byte what it was without the flag |

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
  "schema": 2,
  "version": "0.9.0",
  "ts": "2026-08-11T16:20:51Z",
  "seq": 42,
  "refreshed": ["fast"],          // which cadence tiers ran this cycle
  "link":    {"up": true, "interface": "en0", "type": "wifi", "ip": "…",
              "gateway": "192.168.15.1", "gateway_mac": "10:98:5f:…",
              "ssid": null, "bssid": null},
  "network": {"id": "wifi:mac=10:98:5f:…", "label": "…",
              "group_id": "mac:10:98:5f:…"},
  "vpn":     {"active": false, "type": null, "name": null},
  "gateway": {"loss_pct": 0.0, "rtt_avg_ms": 4.1},
  "wifi":    {"rssi": null, "noise": null, "snr": null, "channel": null},
  "dns":     {"ok": true, "resolver": "192.168.15.1", "elapsed_ms": 12},
  "tcp":     {"any_ok": true, "targets": [{"host": "1.1.1.1", "port": 443,
                                           "ok": true, "elapsed_ms": 30}]},
  "public":  {"ok": true, "ip": "…", "isp": "…", "asn": "AS10429",
              "city": "…", "country": "Brazil", "country_iso": "BR",
              "captive_portal": false},
  "status":  {"severity": "ok", "rules": [], "measurement": "measured",
              "icmp_filtered": false,
              "degraded": false, "paused": false, "cadence_s": 10},
  "changes": [                    // schema 2+; ABSENT when nothing changed
    {"id": "vpn-disconnected", "field": "vpn.active",
     "from": "1", "to": "0", "summary": "VPN disconnected (Mullvad)"},
    {"id": "rule-fired", "field": "status.rules",
     "from": null, "to": "G2", "summary": "Router dropping packets"}
  ]
}
```

## Conventions specific to the stream

- **`gateway.loss_pct` is a rolling-window figure**, not one probe's
  reading: lost×100÷sent accumulated over the last
  `MONITOR_LOSS_WINDOW_PROBES` probes (~100 packets at the defaults,
  refreshed every fast cycle). A percentage is only as fine as its
  denominator; accumulating across probes makes one dropped packet move
  the figure one point and lets routine noise decay out instead of
  swinging the instrument. It resets to `null` on link-down, a network
  change, or an unparseable probe — never silently carries readings
  across a discontinuity.
- **`network.group_id` is the `--history` group key** (`mac:…`, `gw:…` or
  `ssid:…` — the same string `--history` reports in `networks[].id`),
  derived by `lib/netid.sh` from the same inputs as `network.id`, with
  the same precedence `helpers/history.py` groups records by. This is the
  id a consumer joins its stored history with; the raw `network.id` is
  the *record* format (`wifi:mac=…`), which grouping canonicalizes, so
  joining on it never matches. `null` when the network has no identity
  at all, and absent from a CLI older than the field — consumers fall
  back to `network.id` there and simply re-derive grouping themselves.
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
- **`status.measurement`** is separate from health severity. `measured`
  means a fast gateway, internet-loss, or HTTPS reachability probe produced
  a result; `unknown` means the link may still be associated but traffic was
  not successfully tested; `link-down` means there was no default route.
  `unknown` must never be rendered as an all-clear.
- **`status.icmp_filtered`** is TCP-1 holding: real connections work,
  only ping is being dropped. Common on hotel and corporate networks.
  The gateway loss rules (`G1`, `G2`, `G3`) do **not** fire alongside it —
  TCP-1 is evaluated first and suppresses them in `lib/diagnosis.sh` and
  `lib/monitor.sh` alike, so the two engines still name the same rules for
  the same link. (Until v0.10.1 both fired, which put "reboot the router"
  and "the network is up; don't worry" in one report.) The flag remains what
  an alert engine reads to suppress a loss notification, and it is also the
  signal a UI should use to stop presenting `gateway.loss_pct` and the
  latency figures as meaningful: on such a network they are an artefact of
  the probe, not a property of the link.
- **`status.paused`** means `SIGUSR1` suspended probing. Every measurement
  in such a sample is stale by definition; do not plot or alert on it.
- **`changes`** (schema 2+) lists field-level differences from the
  *previous emitted sample*, phrased by the CLI: `id` is a stable kind
  (`public-ip-changed`, `country-changed`, `isp-changed`,
  `vpn-connected`, `vpn-disconnected`, `vpn-name-changed`,
  `wifi-network-changed`, `wifi-roamed`, `interface-changed`,
  `rule-fired`, `rule-cleared`), `summary` is display prose consumers
  render verbatim. A null on either side of a comparison means "not
  measured" and suppresses the entry, so a first slow-tier result is
  not a "change"; to keep that sound, the previous-sample snapshot
  retains the last *known* value of every null-suppressed field
  (a link-down sample must not erase the baseline). Rules are the
  deliberate exception — they are always evaluated, so `rule-fired`/
  `rule-cleared` come from plain set difference; do not "fix" the
  rules path to match the null rule. Rule transitions carry the rule
  ID on one side and `null` on the other (`rule-fired`: `from` null;
  `rule-cleared`: `to` null), so consumers must treat `from`/`to` as
  nullable. `rule-fired`'s `summary` is the rule's title from
  `--rules-catalog` verbatim (e.g. `"Router dropping packets"` for G2);
  `rule-cleared`'s is `"Resolved: "` plus that same title. A rule id the
  bundled catalog doesn't recognize (an older `helpers/rules_catalog.py`
  than the rule that fired) falls back to `"Issue <ID> detected"` /
  `"Issue <ID> cleared"` rather than omitting the entry. A flapping
  condition emits one fired/cleared pair per transition; consumers that
  display events should be prepared to coalesce repeats. The key is
  omitted entirely when nothing changed — including on every first
  sample of a run. Consumers gate on `--capabilities`
  `schemas.monitor >= 2`.

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

## Lifetime

`--monitor` **exits when the process that started it goes away.** A stream
exists for a consumer; a network probe still running with no reader is
invisible and unbounded. Taking `EPIPE` on a closed stdout is not
sufficient on its own — measured, `SIGKILL` of the GUI left the monitor
probing 30 s later — so the parent is checked explicitly each cycle with
`kill -0`. Shutdown lands within one cadence.

If you want a detached recorder, use `--install-watcher`, which is what it
is for.

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
              "runs": 1961, "checks": 1958, "networks": 4},
  "metrics": [{"key": "gateway_rtt_ms", "label": "Gateway RTT", "unit": "ms",
               "direction": "lower_is_better", "samples": 1959}],
  "networks": [{"id": "mac:10:98:5f:…", "label": "…", "synthesized": false,
                "bridged_from": [], "first_seen": "…", "last_seen": "…",
                "run_count": 35, "check_count": 32,
                "gateways": [], "isps": [], "ssids": [],
                "metric_samples": {"gateway_rtt_ms": 32},
                "metric_stats": {"gateway_rtt_ms":
                  {"median": 3.21, "p10": 2.90, "p90": 8.40},
                  "wifi_rssi_dbm": null},
                "severity_counts": {}}],
  "runs": [{"id": "2026-08-11T20:51:19Z.a3f9c1d2", "ts": "…",
            "network_id": "mac:10:98:5f:…", "version": "0.6.1",
            "run_mode": "full",
            "severity": "warn", "diagnosis_count": 1, "rules": ["M1"],
            "root_cause": "…", "metrics": {"gateway_rtt_ms": 3.4}}]
}
```

- **`id` addresses a run; `ts` does not.** Timestamps have one-second
  resolution and back-to-back runs collide, which is why the store already
  deduplicates on *(timestamp, canonical JSON)* rather than on the
  timestamp alone. An id is that same pair made printable: the timestamp, a
  dot, and the first 8 hex characters of the SHA-256 of those same
  canonical bytes. Byte-identical records collapse to one run and therefore
  to one id, so an id always names exactly one run. `ts` is unchanged and
  still there.
  Parse an id by splitting on the **last** dot — the suffix is fixed-width
  hex, and the rule stays correct if timestamps ever gain sub-second
  precision. The separator is `.` and not `#` because under zsh with
  `EXTENDED_GLOB` (the default in many setups) an unquoted `--show=…#…` is
  a glob pattern and fails with "no matches found".
  Records whose *identity fields* are literally redacted are dropped before
  ids are handed out — but as of v0.7.0 that is no longer what a `--redact`
  run writes to disk (see the note below and `run_id` above): its stored
  record is the ordinary private build, so it gets an ordinary id and
  *is* reachable with `--show`. What `--redact` actually withholds is
  narrower — the `run_id` field on its own `--json` output — not the
  record's existence in the store.

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
- **`networks[].metric_stats`** is `{median, p10, p90}` for every key in
  `metrics[]`, over the exact same per-network population
  `metric_samples` counts — the same `quantile()`/median arithmetic
  `--show`'s `comparison` uses, reused rather than reimplemented. It
  carries no `value`, `direction` or `verdict`: this is what a network's
  numbers look like, not whether any one run's reading was good, which
  stays `--show`'s question alone. `p10`/`p90` follow
  `THRESH_COMPARE_TAIL_PCTL`, the same cutoff and the same "named for its
  default of 10" caveat as `--show`'s `p10`/`p90` below.
  Below `THRESH_COMPARE_MIN_SAMPLES` **the whole per-metric block is
  `null`**, not a partial object. This is the same cutoff `--show` judges
  `insufficient_data` against, applied differently on purpose: `--show`
  still returns `median`/`p10`/`p90` below the cutoff and withholds only
  the `verdict` — a single run's reading still needs the band drawn under
  it even when there isn't enough history to judge that reading against
  it — while `metric_stats` withholds the numbers themselves, because
  there is no single reading to give context to here, only a population to
  describe, and a population too small to describe honestly gets `null`
  rather than a spread stated with more confidence than the sample
  supports.
  `n` is deliberately not repeated inside it: the identical count already
  lives in `metric_samples` for the same key, and a plain
  `netdiag --history` now needs `THRESH_COMPARE_*` in the environment for
  this reason, the same way `--show` always has. One asymmetry a consumer
  must not paper over: `metric_stats` carries all 13 keys from `METRICS`
  for every network — null blocks included, for metrics that network never
  recorded at all — while `metric_samples` carries only the keys some run
  on that network actually measured. A key present (as `null`) in
  `metric_stats` is not guaranteed to exist in `metric_samples` at all;
  code iterating `metric_stats` to look up a matching `n` must check for
  the key rather than assume it.
- **`run_count` counts records; `check_count` counts checks.** They differ
  by the partial runs — see [`run_mode`](#run_mode). `severity_counts` and
  `counts.checks` follow `check_count`; `metric_samples` and
  `metrics[].samples` follow `run_count`, because a partial run's *numbers*
  are exactly why it was stored. `runs[].run_mode` is `null` on records
  written before v0.9.0; treat that as a check.
- **A run's `metrics` omits what was not measured.** Absent, never zero —
  the same distinction the full schema draws, and for the same reason.
- **Redacted records are dropped and counted.** A run recorded with
  `--redact` has `network.id = "wifi:mac=[redacted]"`, shared with every
  other redacted run on every other network, so it can never join a real
  group. (`lib/output.sh` stopped producing them in v0.7.0; these are the
  historical ones.)

---

# `netdiag --show=<id>` schema

`netdiag --show=ID` emits one **stored** run: the record exactly as it was
written, where it sits in that network's history, and how each of its
metrics compares to every other run on the same network. One JSON object on
stdout, exit 0.

The id comes from `--history`. A bare timestamp is also accepted, because
that is what a person has in front of them in a log filename — it resolves
when it names exactly one run, and exits 3 listing the candidates when it
does not.

```jsonc
{
  "schema": 1,
  "version": "0.9.0",                    // netdiag rendering the view, not
                                         // the one that recorded the run
                                         // (that is run.version)
  "id": "2026-08-11T20:51:19Z.a3f9c1d2",
  "run": { /* the complete stored record — every key of the --json schema
              above, unmodified */ },
  "context": {
    "network_id": "mac:10:98:5f:…",
    "runs_on_network": 1915,
    "checks_on_network": 1908,
    "position": 1843,
    "first_seen": "2026-05-30T07:55:33Z",
    "last_seen":  "2026-08-11T20:51:19Z"
  },
  "comparison": {
    "metrics": {
      "gateway_rtt_ms": {
        "value": 3.745, "median": 3.21, "p10": 2.90, "p90": 8.40,
        "percentile": 62, "n": 1900,
        "direction": "lower_is_better",
        "verdict": "typical",
        "summary": "3.7 ms — typical for this network (median 3.2 ms across 1,900 checks)."
      }
    }
  }
}
```

`run` decodes with the same model as a `--json` run — stored records are
written by the same `build_json`, so a two-month-old record needs no
special case. `context` holds plain facts and no judgement. `comparison`
holds the judgement, and `summary` is rendered verbatim: it is the CLI's
sentence, the way `diagnosis[].summary` is.

## Definitions

- **The comparison population is every run on that network**, not a recent
  window. One rule with nothing to configure; a consumer that wants a
  recent view narrows its own charts.
- **The population includes partial runs**, which is deliberate: a
  `--speed-only` run exists precisely to thicken the throughput sample.
  `context.checks_on_network` is the same population minus those, so a UI
  can say "1,915 runs, 1,908 checks" instead of implying every stored
  record examined the whole network.
- **`context.network_id` is the grouped key** — the same string
  `--history` reports in `networks[].id` and `runs[].network_id`, so the
  two join. It is not the raw `network.id` from the record: grouping is
  what reconciles four eras of netdiag's identity scheme.
- **`context.runs_on_network` counts every run; a metric's `n` counts the
  ones that recorded it.** They differ, and the gap is the point — 1,915
  checks but only 38 bufferbloat readings.
- **`context.position` is 1-based, chronological, oldest first.**
- **`percentile`, `median`, `p10` and `p90` are computed on the raw value
  ascending**, with no direction applied. Ties are averaged, so a metric
  that reads 0.0 % in every run sits at the 50th percentile rather than the
  100th. Direction is applied when deriving `verdict`, and only there.
- **`p10`/`p90` are the edges of the band the verdict was drawn from.**
  They follow `THRESH_COMPARE_TAIL_PCTL`; the key names are written for its
  default of 10, so a UI shading "normal for this network" shades exactly
  what was judged.
- **`value` is `null` when this run did not measure the metric**, never
  `0` — the same distinction the full schema draws, and for the same
  reason.

## `verdict`

A closed set, so a UI can style it without parsing prose:

| verdict | meaning |
|---|---|
| `typical` | inside the normal band for this network |
| `better` | in the tail on the good side |
| `worse` | in the tail on the bad side |
| `best` | the best value in the sample |
| `worst` | the worst value in the sample |
| `insufficient_data` | fewer than `THRESH_COMPARE_MIN_SAMPLES` readings |
| `not_measured` | this run did not record the metric |

`not_measured` wins over `insufficient_data`: a metric this run never
recorded says so, whether or not the network has enough history behind it.
`percentile` is `null` for both.

Both cutoffs live in [`lib/thresholds.sh`](../lib/thresholds.sh) and reach
`helpers/history.py` through the environment; the helper refuses to run
without them rather than carrying a default. One symmetric tail rather than
a "better" and a "worse" percentile, because for throughput the *low*
percentile is the bad end, and a cutoff whose meaning flips per metric is
one that eventually gets applied the wrong way round:

```
lower tail  = percentile <= TAIL_PCTL
upper tail  = percentile >= 100 - TAIL_PCTL
lower_is_better  → lower tail is "better", upper tail is "worse"
higher_is_better → lower tail is "worse",  upper tail is "better"
```

`best` and `worst` replace `better` and `worse` only when the value is the
extreme of the sample, so a network whose every run measured the same value
stays `typical`.

The metrics compared are exactly the ones `--history` charts — the same
table, which already states a `direction` per metric. `comparison` is
always present: when a metric has too few readings every entry says
`insufficient_data` rather than the block going missing, so "no comparison"
and "too few checks" cannot render as the same thing.

## Errors

| case | behaviour |
|---|---|
| id not found in the live store or the archive | exit `3`, reason on stderr |
| a bare timestamp matching more than one run | exit `3`, candidate ids listed on stderr |
| missing or empty `--show` argument | exit `3` — a usage error |
| a legacy record whose identity fields were literally redacted (pre-v0.7.0) | it has no id, so it is unreachable by construction |

Exit `2` is never used here: it is reserved for a real diagnosis, so a
wrapper can keep telling a mistyped id apart from a broken network.

---

# `netdiag --share[=ID|-]` schema

`netdiag --share` is the **one mode in this document that emits plain
text, not JSON** — a pasteable report, not a machine-readable object.

It exists because there is no redacted copy sitting in the store to read
back. `lib/output.sh:160-163` saves `REDACT`, forces it to `0` while
building the record appended to history, then restores it, so every
stored run holds full detail regardless of the flags it was invoked
with — and `helpers/history.py:355` drops any record that *was* written
under `--redact` from the store entirely, because a masked record's
`network.id` is the literal string `wifi:mac=[redacted]`, shared with
every other redacted run on every other network. So redacting a *past*
run has to happen at read time, against whatever JSON `--show` would
return for it. `helpers/share.py` does exactly that.

Three input forms:

| form | source |
|---|---|
| `--share` (bare) | the newest run in the store |
| `--share=ID` | that stored run — ids come from `--history` |
| `--share=-` | one run's JSON read from stdin, no store lookup — the app's own in-memory result shares identically to a run from last week |

The output is never colored, so it pastes cleanly into a support chat, a
forum post, or an email.

## Masked vs. kept

`helpers/share.py` mirrors `helpers/emit_json.py`'s `_REDACT_ENV` field
for field (`helpers/emit_json.py:275-276`), substring-scrubbing the same
values out of the record itself rather than the environment — there is
no live run here to source `NETDIAG_*` vars from, only a JSON object read
from stdin or the store.

| field | masked? | why |
|---|---|---|
| `public.ip` | masked | identifies the household |
| `public.city` | masked | identifies the household |
| `interface.ip` | masked | identifies the household |
| `interface.gateway_mac` | masked | identifies the router |
| `wifi.ssid` | masked | identifies the household |
| `wifi.bssid` | masked | identifies the router |
| `ipv6.global_addr` | masked | identifies the household |
| `ipv6.gateway` | masked | EUI-64-derived from the router's MAC, so leaving it in republishes `interface.gateway_mac` sitting right next to it |
| `public.isp` | kept, deliberately | names a provider, not a person — needed to reason about the fault |
| `public.asn` | kept, deliberately | same reason as `isp` |
| `public.country` / `public.country_iso` | kept, deliberately | two characters is too short to substring-replace safely without corrupting unrelated text |
| RFC1918 addresses (e.g. `gateway.ip`, `interface.gateway`, `interface.dhcp_router`) | kept, deliberately | identify nobody, and blanking them would gut the router/NAT rows. `interface.dhcp_router` is the same class of value as `interface.gateway` and follows the same rule — which also keeps `N1c`'s "try http://…" advice actionable in a shared report |
| `network.id` / `network.label` | kept, deliberately | composites of values already masked above (`wifi:ssid=[redacted],mac=[redacted]`) — the parts that identify anything are already gone |

Longest-secret-first ordering and a 3-character minimum are part of the
algorithm, not incidental: a longer secret is masked before a shorter one
that happens to sit inside it (an SSID containing a street number that
also appears alone elsewhere), or the shorter replacement would run first
and leave a fragment of the longer secret exposed; a 1–2 character
replacement would corrupt ordinary prose (English is full of 2-letter
words) rather than protect anything.

## Errors

| case | behaviour |
|---|---|
| empty store, bare `--share` | exit `3` — "no stored run to share yet — run a check first" |
| `--share=ID` naming a run not in the store | exit `3` — "no stored run to share (id: ID)" |
| `--share=-` given input that is not valid JSON | exit `3` |

Exit `2` is never used here either: it is reserved for a real diagnosis.

---

# `netdiag --version`

Prints `netdiag <VERSION>` to stdout and exits 0. No log file, no
network, no dependency check — the one thing every version of this
CLI has always been able to answer.

```console
$ netdiag --version
netdiag 0.9.0
```

---

# `netdiag --capabilities` schema

`netdiag --capabilities` writes one JSON object to stdout and exits 0: a
handshake a GUI can use to find out what this install of the CLI actually
supports before it relies on a feature, rather than parsing `--version`'s
semver and guessing. Early exit, same family as `--help`: no probing, no
log file, no `~/net-diag` writes, sudo-free, and it succeeds even when
every optional dependency below is missing.

```jsonc
{
  "schema": 1,
  "version": "0.9.0",
  "schemas": {"run": 1, "monitor": 2, "history": 1, "show": 1,
              "rules_catalog": 1, "signal_scale": 1, "progress": 1},
  "features": ["capabilities", "version", "progress", "monitor", "history",
               "show", "redact", "speed-only", "dns-only",
               "bufferbloat-only", "ping-only", "watcher", "rules-catalog",
               "signal-scale"],
  "deps": {
    "bash": "5.2.37",
    "python3": "3.9.6",
    "jq": true,
    "speedtest": "ookla",
    "mtr": false,
    "gping": false
  }
}
```

- **`schema`** versions this document's own shape, separately from
  every entry inside `schemas`.
- **`schemas`** carries the schema number of seven other outputs.
  `monitor`, `history`, `show`, `rules_catalog` and `signal_scale` mirror
  a `"schema"` field each of those already emits (`lib/monitor.sh`,
  `helpers/history.py`, `helpers/rules_catalog.py`,
  `helpers/signal_scale.py`) — see their sections above and below. `run`
  (the `--json` output) and `progress` (the `--progress` event stream) do
  not embed a schema field as of v0.9.0; both report `1` here as the
  number a future field would start at, and this note is that field's
  documentation until one exists.
- **`features`** is an open set, not a closed enum — expect it to grow
  as new CLI surface ships. A GUI checks membership (`"redact" in
  features`), not the array's length or order.
- **`deps.bash`** is the version of the bash interpreter actually
  running the script — after netdiag's own re-exec into Homebrew bash 5
  if it started under macOS's system bash — as `major.minor.patch`.
- **`deps.python3`** is `null` if python3 is not on `PATH`. In practice
  this is close to unreachable: `--capabilities` builds its JSON with a
  python3 helper the same way `--json`/`--history`/`--show` already do,
  so a machine that cannot run python3 cannot produce this object at all.
- **`deps.jq`**, **`deps.mtr`**, **`deps.gping`** are booleans: present
  on `PATH` or not. None of the three is required for `--capabilities`
  itself.
- **`deps.speedtest`** is `"ookla"`, `"cli"` (the `speedtest-cli` Python
  package), or `null` if neither is installed — from the same
  `speedtest_flavor()` `lib/speedtest.sh` uses to pick an implementation
  for a real run.

---

# `netdiag --rules-catalog` schema

`netdiag --rules-catalog` writes one JSON object to stdout and exits 0:
every rule the diagnosis engine (`lib/diagnosis.sh`, `lib/wan.sh`,
`lib/output.sh`) and the live monitor (`lib/monitor.sh`) can emit,
described once, plus a glossary of the jargon terms the report card shows.
Same family as `--capabilities` — early exit, no probing, no log file, no
`~/net-diag` writes, sudo-free — and this schema is additive: a future
release only ever adds fields to an entry or new entries to `rules` /
`metrics`, never removes or repurposes one, so a consumer that reads
today's fields keeps working against tomorrow's catalog.

```jsonc
{
  "schema": 2,
  "version": "0.9.0",
  "rules": [
    {
      "id": "G2",
      "title": "Router dropping packets",
      "category": "router",
      "severity": "critical",
      "scope": "both",
      "blurb": "Packets are being dropped between your Mac and your router even though the WiFi signal is strong, which points at the router itself rather than the wireless link. A reboot (power off, wait, then power back on) clears this in most cases.",
      "doc": "DIAGNOSIS-RULES.md#g2--gateway-loss-with-healthy-wifi"
    }
  ],
  "metrics": [
    {
      "key": "mtu",
      "label": "Packet size (MTU)",
      "help": "The biggest chunk of data your connection can send in one piece. If it's smaller than usual, some websites and video calls can stall or fail to load."
    }
  ]
}
```

- **`schema`** versions this document's own shape, independent of
  `--capabilities`'s `schemas` block, `--json`'s implicit `1`, and every
  other schema number this project tracks.
- **`rules`** is exhaustive as of the running version: one entry per rule
  ID `add_diag` or `_mon_add_rule` can actually record, matched against
  those call sites by `tests/test_rules_catalog.bats` so the two can't
  drift apart silently. `UP-1` is the one documented exception — reserved
  in `docs/DIAGNOSIS-RULES.md` for a rule that has never fired, because
  the Report card already states UPnP status directly and a second
  restatement would say the same fact twice.
- **`title`** is a short plain-English noun phrase, not a sentence — the
  label a chip or a list row shows.
- **`category`** is the measurement family the rule judges (`router`,
  `internet`, `dns`, `wifi`, `load`, `mtu`, `speed`, `clock`, `ipv6`,
  `vpn`, `lan`, `dhcp`, `topology`, `baseline`), for tinting a
  report-card row — deliberately not the same axis as `severity`, so a
  `varies`-severity rule like `B1` still has one fixed row to live on.
- **`severity`** is `info` / `warn` / `critical` for a rule that always
  fires at one severity, or `varies` for the handful that grade by
  magnitude within a single `add_diag` call site (`B1`, `B2`, `M1`,
  `NT-1`) — the actual severity of *this* incident always arrives
  separately, in `diagnosis[].severity`. This field describes the rule,
  never a reading.
- **`scope`** is `scan` (only `lib/diagnosis.sh` / `lib/wan.sh` /
  `lib/output.sh` evaluate it), `monitor` (only `lib/monitor.sh::_mon_rules`
  does — `CP-1` is the sole member, because a captive-portal probe has no
  scan-mode equivalent), or `both`.
- **`blurb`** is general prose about what the rule means, what typically
  causes it, and what helps — 1–3 sentences, adapted from
  `docs/DIAGNOSIS-RULES.md`. It is **not** per-incident text: the string a
  user reads about *this run's* fault is, and remains,
  `diagnosis[].summary`, which carries this run's own numbers. `blurb`
  stays qualitative on purpose — no embedded numeric cutoffs — because a
  threshold belongs in exactly one place (`lib/thresholds.sh`), and
  `doc` is where the actual number lives.
- **`doc`** is a GitHub-style anchor into `docs/DIAGNOSIS-RULES.md` for
  the full trigger condition, evidence, and rationale.
- **`metrics`** is a glossary, not a rule list: one entry per jargon term
  the report card shows (`router`, `internet`, `dns`, `wifi_signal`,
  `bufferbloat`, `mtu`, `speed`, `clock`, `packet_loss`, `latency`,
  `jitter`), for a `questionmark.circle` hint next to a row label. Added
  in schema `2`; `rules` is unchanged from schema `1`.
  - **`key`** is what a GUI looks the entry up by — stable, never
    re-used for a different meaning.
  - **`label`** is the short user-facing name for the term (matches the
    report card's own row label where one exists).
  - **`help`** is 1–2 plain sentences explaining the term to someone who
    has never heard it, with no jargon and no embedded numeric
    threshold — same discipline as `blurb`, for the same reason.

---

# `netdiag --signal-scale` schema

`netdiag --signal-scale` writes one JSON object to stdout and exits 0:
the four bands this install's Wi-Fi RSSI thresholds define — Excellent,
Good, Fair, Weak — so a GUI can turn a raw dBm reading into the word a
person actually reads, without deriving a boundary of its own. Same
family as `--rules-catalog` and `--capabilities` — early exit, no
probing, no log file, no `~/net-diag` writes, sudo-free.

```jsonc
{
  "schema": 1,
  "bands": [
    {"min_dbm": -55, "label": "Excellent", "tone": "good",
     "blurb": "Your Mac has a strong radio signal to the access point. That does not test whether the router or internet path is delivering traffic."},
    {"min_dbm": -70, "label": "Good", "tone": "ok",
     "blurb": "Your Mac has a solid radio signal to the access point. Signal strength alone cannot confirm that websites will load."},
    {"min_dbm": -75, "label": "Fair", "tone": "warn",
     "blurb": "Your radio signal is on the weaker side, but this reading still does not identify whether an internet problem is local Wi-Fi, the router, or the provider."},
    {"min_dbm": null, "label": "Weak", "tone": "bad",
     "blurb": "Your radio signal is weak or obstructed. Confirm the router and internet path with a reachability check before assuming signal strength is the cause."}
  ]
}
```

- **`schema`** versions this document's own shape.
- **`bands`** is always exactly 4 entries, strongest signal first. A
  consumer picks a reading's band by walking the array in order and
  taking the first one whose `min_dbm` the reading is `>=` — never by
  re-deriving a boundary of its own, which is the whole reason this mode
  exists instead of a GUI-side lookup table.
  - **`min_dbm`** is the band's lower bound in dBm (RSSI values are
    negative; closer to zero is stronger), taken directly from
    `lib/thresholds.sh` — `THRESH_WIFI_RSSI_EXCELLENT_DBM`,
    `THRESH_WIFI_RSSI_G1_DBM`, and `THRESH_WIFI_RSSI_WEAK_DBM`
    respectively. `null` on the last band: "Weak" has no floor.
  - **`label`** is the exact user-facing word: `"Excellent"`, `"Good"`,
    `"Fair"`, or `"Weak"`.
  - **`tone`** is `good` / `ok` / `warn` / `bad` — a closed set for
    tinting, never a color or a hex code.
  - **`blurb`** is one plain sentence a tooltip can show, with no
    embedded numeric threshold — same discipline as `--rules-catalog`'s
    `blurb` / `metrics[].help`.
