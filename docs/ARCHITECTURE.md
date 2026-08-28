# Architecture

## Current shape (v0.10.0)

`bin/netdiag` is a ~230-line orchestrator. Every section lives in its
own `lib/*.sh` module with a `Reads / Writes / Entry` header comment.
Cross-module variables are declared in `lib/globals.sh` so the data
flow is greppable: search for `WIFI_RSSI` and you'll find the one place
that initialises it (`globals.sh`), the one module that sets it
(`lib/wifi.sh`), and the modules that read it (`lib/diagnosis.sh`,
`lib/output.sh`, plus `helpers/emit_json.py` via the
`NETDIAG_WIFI_RSSI` env var).

```
bin/netdiag                  # argparse, mode dispatch, source lib/*.sh, call *_run in order
lib/common.sh                # printing helpers, add_diag, with_timeout, launch_parallel, setvar
lib/globals.sh               # every cross-module variable, initialised
lib/iface.sh                 # interface + default gateway
lib/vpn.sh                   # VPN active? (scutil, tailscale, utun route)
lib/wifi.sh                  # SSID/BSSID/sec + RSSI/noise/channel via wdutil
lib/wifi_scan.sh             # neighbourhood AP scan via system_profiler
lib/wifi_disconnect.sh       # roam / link-down events from `log show`
lib/dhcp.sh                  # DHCP lease detail from ipconfig getsummary
lib/arp.sh                   # duplicate-IP / gateway-incomplete check
lib/gateway.sh               # gateway ping (10× ICMP)
lib/public.sh                # ifconfig.co + captive portal + TARGET ping
lib/bufferbloat.sh           # loaded-vs-idle latency probe (sequential — loads the link)
lib/mtu.sh                   # path MTU via DF-set pings
lib/dns.sh                   # DNS resolution checks (parallel-safe)
lib/ipv6.sh                  # IPv6 parity (parallel-safe)
lib/tcp_reach.sh             # TCP/443 reach panel (parallel-safe)
lib/ntp.sh                   # sntp drift check (parallel-safe)
lib/speedtest.sh             # Ookla / speedtest-cli
lib/traceroute.sh            # traceroute to 1.1.1.1 + optional TARGET
lib/mtr.sh                   # mtr -j -c 60 under sudo OR parallel per-hop fallback
lib/wan.sh                   # NAT/WAN topology: dual-WAN, double-NAT, UPnP/NAT-PMP
lib/thresholds.sh            # every numeric cutoff a rule fires on (sourced first)
lib/diagnosis.sh             # rule set → DIAG[] + DIAG_SEV[] → sorted printout
lib/monitor.sh               # --monitor: streaming samples + the same rule set
lib/output.sh                # JSON build, baseline regression check, "report saved" line
lib/gping.sh                 # exec gping at the end
lib/watch.sh                 # --watch loop
lib/launchd.sh               # --install-watcher / --uninstall-watcher
helpers/emit_json.py         # bash → JSON
helpers/baseline.py          # historical median / regression detector
helpers/summary.py           # --summary aggregation
helpers/history.py           # --history: network identity + grouping
                             # --show: one run + its comparison (it judges,
                             #   so its cutoffs come from lib/thresholds.sh)
helpers/monitor_sample.py    # one --monitor sample → one JSON line
helpers/capabilities.py      # --capabilities: the version/feature handshake
helpers/rules_catalog.py     # --rules-catalog: rule titles/blurbs for the GUI
helpers/speedtest_result.py  # speed test's final result JSON → tab-separated
                             #   fields, replacing ~10 jq calls (see below)
gui/                         # SwiftUI menu-bar client (SwiftPM, macOS 14+)
```

## The CLI/GUI split (v0.10.0)

`gui/` is a **client**. It renders; it does not decide.

```
CLI (bash + Python) — owns every measurement and every threshold
├── netdiag --json         full scan, ~60 fields
├── netdiag --history      normalized, network-grouped history
├── netdiag --monitor      streaming JSONL, one compact sample per line
├── netdiag --show=ID      one stored run + how it compares to its network
├── netdiag --progress     phase events on fd 3 while a run happens
└── lib/thresholds.sh      cutoffs shared by diagnosis.sh, monitor.sh
                           and helpers/history.py

GUI (SwiftUI) — owns rendering, OS events, and alert policy only
├── consumes the three modes above
├── CoreWLAN + NWPathMonitor for instant network-change events
├── alert state machine: dwell / hysteresis / cooldown / auto-resolve
└── never computes a threshold or writes a diagnosis string
```

Four consequences worth stating, because each was a decision rather than
a default:

1. **`lib/thresholds.sh` exists because there are now two judges.** The
   scanner produces one verdict per run; the monitor produces one every
   few seconds. Sharing the constants is what stops the menu-bar dot from
   contradicting the report it links to, and `tests/test_monitor.bats`
   asserts rule-for-rule parity across eleven network states.

2. **Network identity stayed in Python.** `helpers/history.py` does the
   grouping — parsing composite ids, backfilling records that predate
   `lib/netid.sh`, bridging weak groups — rather than Swift, so identity
   logic lives once, in the same language as the code that writes the
   records. This is the same split the decision below already records.

3. **Alert *policy* is the GUI's, alert *facts* are the CLI's.** The
   monitor reports G2 even when ICMP is filtered, because withholding it
   would break parity with a scan; the app reads `status.icmp_filtered`
   and declines to notify. Same facts, one place to decide each thing.

4. **`helpers/judgement.py` is the one pair-table two judging surfaces
   both read.** `--summary`'s text report and `--history`'s `judged`
   block (`networks[].judged`, schema 2) each turn a metric's stored
   median into a verdict — one for a person reading the terminal, one
   for a GUI's Trends chart — and before this module existed each held
   its own copy of the same six thresholds, on a collision course with
   the other. `judgement.py` is the single table (metric key → warn
   env, crit env, direction, phrase) both `helpers/summary.py` and
   `helpers/history.py` read, so the two can now only ever agree: a
   menu-bar app rendering `judged.summary` and a terminal printing
   `--summary`'s own line describe the same network from the same six
   rows, because there is only one place either could have read them
   from.

## Bash vs Python helper — decision (v0.2.0, amended v0.8.0)

Bash for orchestration + per-check probes; Python helpers under
`helpers/` for anything that needs structured JSON construction or
multi-file aggregation. `lib/*.sh` modules (introduced in v0.3.0) keep
the bash side honest — each module is small and unit-testable via
`bats`.

The split's rationale stands:

1. **JSON emission** matching the spec's ~60-field schema with nullable
   nested objects — bash + `jq -n --arg` would be ~200 lines of
   escaping; Python `json.dumps()` over a dict is ~30.
2. **Baseline aggregation** (read N `~/net-diag/*.json` files, compute
   medians per metric, surface regressions) — array math + sorted-list
   selection in bash is painful.
3. **Per-hop `mtr` JSON** — `jq` inline is fine; small enough not to
   need Python.

**Amendment (v0.8.0): a fourth reason, and a new obligation.**
`--show` scores a run against every other run on its network — sorting a
metric's whole population, taking a median and p10/p90, and computing a
percentile rank with **ties averaged**. That is `statistics` and a sort in
Python; in bash it is a hand-rolled numeric sort per metric per run.

The obligation is the part worth stating. Deciding whether a number is
good is what `lib/thresholds.sh` exists to own, so `helpers/history.py`
became the **third** file bound by that rule, alongside `lib/diagnosis.sh`
and `lib/monitor.sh`. Its two cutoffs reach Python through the
environment, and the helper **refuses to start** if they are unset rather
than carrying a default — a default is a second home for a number that
has exactly one, and the two diverge silently the first time either is
tuned. `tests/test_thresholds.bats` fails the build on an inline numeric
cutoff in any of the three.

**Amendment (unreleased): a fifth reason, running the other direction.**
Every reason above is about Python *producing* JSON. `helpers/speedtest_result.py`
instead *consumes* it — reading the speed test's final result object
(Ookla's or speedtest-cli's) on stdin and writing back a tab-separated
line — and the rationale is dependency removal rather than escaping:
those ~10 `jq -r`/`jq -e` calls were the last thing on the default run
path that hard-required `jq`, so replacing them with `json.loads()` plus
five shape-checked field lookups means a machine with just bash 5 and
python3 gets a real speed test instead of a "brew install jq" hint.

**Runtime requirement:** Python 3 (system `/usr/bin/python3` on macOS
14+ is fine; no extra packages).

## Parallelism

`launch_parallel <name> <fn>` forks `<fn>` into a background subshell
with its stdout redirected to a per-section buffer file and an env-var
`$NETDIAG_PAR_VARS` set so the function can persist variables across
the boundary via `setvar NAME "value"`. `collect_parallel` waits on all
launches, replays each buffer to terminal + `$LOG` in launch order, and
sources each vars file.

Sections that share the WAN link (bufferbloat, traceroute, mtr) stay
sequential — running them in parallel would skew each other's latency
measurements. The fan-out includes: DNS, IPv6, TCP reach, NTP, WiFi
neighbourhood scan, WiFi disconnect history, dual-WAN probe,
UPnP/NAT-PMP probe.

On a healthy macOS 14+ link the parallel batch is bound by
`system_profiler SPAirPortDataType` (~15 s on this Mac). Per the v0.2.0
spec budgets (≤ 30 s full / ≤ 8 s `--quick`), full-run is comfortably
inside; `--quick` is on the edge depending on `sntp` latency.

## Per-check timeout

`with_timeout SECS cmd...` runs `cmd` with a wall-clock cap. Internally
it forks two subshells (the command itself and a sleeper that SIGTERMs
the command). Returns the command's exit code, or 124 on timeout — the
GNU `timeout(1)` convention. Applied at probe-call sites (DNS `dig`,
TCP `nc`, `traceroute`, `mtr`, `sntp`); doesn't replace per-tool flags
like `dig +time=2` but bounds the wrapped pipeline regardless of how
each tool handles its own timeouts.

## Diagnosis ordering

`add_diag <sev> <msg>` appends parallel `DIAG[]` / `DIAG_SEV[]` entries
and bumps `MAX_SEVERITY` (0=healthy → 1=warn → 2=critical → drives the
exit code). `lib/diagnosis.sh` walks rules in fixed order, then sorts
the accumulator into critical → warn → info before printing; the first
emitted line becomes `most_likely_root_cause` in the JSON.

The WAN rules (WAN-1, NAT-1, UP-1) live in `lib/wan.sh::wan_diagnosis_run`
which `lib/diagnosis.sh` calls via `declare -f wan_diagnosis_run`
defensive check (the call site stays scoped to the existing rule set).
