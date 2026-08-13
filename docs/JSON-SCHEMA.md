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

## `run_mode`

Which shape of run produced this record. A closed set:

| value | flags | counts as a check? |
|---|---|---|
| `full` | none | yes |
| `quick` | `--quick` | yes |
| `speed-only` | `--speed-only` | no |
| `mtu-only` | `--mtu-only` | no |
| `wifi-only` | `--wifi-only` | no |

Every record looked alike before v0.9.0, which is why "1,986 checks" on a
network overstated what had actually been measured: a `--quick` run skips
bufferbloat, mtr, the speed test, the loss probe and the WiFi scan, and a
focused run skips almost everything.

A **partial mode** — anything ending `-only` — contributes its measurements
and nothing else. `helpers/history.py` counts its metrics into
`metric_samples`, and excludes it from `check_count`, `counts.checks` and
`severity_counts`. A speed test is a measurement, not an opinion about the
network's health.

The suffix is the rule rather than a list of the three that exist today,
because every focused mode comes from the same `FOCUS` mechanism and every
`FOCUS` flag is named `--<section>-only`. A list would go stale the day a
`--dns-only` landed, and it would go stale silently, by counting the new
mode as a full check.

**`null` on every record written before v0.9.0**, and absence decodes as
"unknown, treat as a check" — those runs were full or quick ones, and
reclassifying them would rewrite two months of history.

`--speed-only` is the one focused mode that *is* recorded. `--mtu-only` and
`--wifi-only` still write no history record, which is the behaviour their
existing records were written under.

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
  "schema": 1,
  "version": "0.9.0",
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
                "metric_samples": {}, "severity_counts": {}}],
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
  Redacted records are dropped before ids are handed out, so a run recorded
  with `--redact` has no id and cannot be opened with `--show`.

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
| record written with `--redact` | it has no id, so it is unreachable by construction |

Exit `2` is never used here: it is reserved for a real diagnosis, so a
wrapper can keep telling a mistyped id apart from a broken network.

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
  "schemas": {"run": 1, "monitor": 1, "history": 1, "show": 1, "progress": 1},
  "features": ["capabilities", "version", "progress", "monitor", "history",
               "show", "redact", "speed-only", "watcher"],
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
- **`schemas`** carries the schema number of five other outputs.
  `monitor`, `history` and `show` mirror a `"schema"` field each of
  those already emits (`lib/monitor.sh`, `helpers/history.py`) — see
  their sections above. `run` (the `--json` output) and `progress` (the
  `--progress` event stream) do not embed a schema field as of v0.9.0;
  both report `1` here as the number a future field would start at, and
  this note is that field's documentation until one exists.
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
