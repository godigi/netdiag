# Architecture

## Current shape (v0.3.0)

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
lib/diagnosis.sh             # rule set → DIAG[] + DIAG_SEV[] → sorted printout
lib/output.sh                # JSON build, baseline regression check, "report saved" line
lib/gping.sh                 # exec gping at the end
lib/watch.sh                 # --watch loop
lib/launchd.sh               # --install-watcher / --uninstall-watcher
helpers/emit_json.py         # bash → JSON
helpers/baseline.py          # historical median / regression detector
helpers/summary.py           # --summary aggregation
```

## Bash vs Python helper — decision (v0.2.0, unchanged)

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
