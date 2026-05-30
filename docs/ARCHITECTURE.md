# Architecture

> Status: skeleton. Filled in as the script grows past ~700 bash lines and the
> bash-vs-Python split decision becomes load-bearing.

## Current shape (v0.1.0)

Single bash entry point at `bin/netdiag`. ~300 lines. No modules yet.

## Bash vs Python helper — decision (v0.2.0)

**Choice:** bash for orchestration + per-check probes; Python helpers
under `helpers/` for anything that needs structured JSON construction or
multi-file aggregation. Modules under `lib/*.sh` come in v0.3 — keeping
v0.2.x single-file for atomic-deploy simplicity.

**Why this split:** `awk`/`sed` parsing of fixed-format command output is
fine for one-shot extraction (RSSI from `wdutil`, RTT from `ping`). It
breaks down for:

1. **JSON emission** matching the spec's schema (~50 fields, nullable,
   nested) — bash + `jq -n --arg` would be ~200 lines of escaping;
   Python `json.dumps()` over a dict is ~30 lines.
2. **Baseline aggregation** (read N `~/net-diag/*.json` files, compute
   medians per metric, surface regressions vs current) — array math
   and sorted-list selection in bash is painful.
3. **Per-hop `mtr` JSON** — already handled with `jq` inline; small
   enough not to need Python.
4. **`log show` timeline** — currently a grep + count; if it grows into
   structured event tracking, move to Python.

**Helpers ship in v0.2.0:** `helpers/emit_json.py` (reads env vars,
writes schema-conformant JSON to stdout), `helpers/baseline.py` (reads
last N JSON snapshots, computes medians, prints regression list).

**Runtime requirement:** Python 3 (system /usr/bin/python3 on macOS 14+
is fine; no extra packages).

## Module layout (planned)

```
bin/netdiag                      # arg-parse + orchestration + diagnosis
lib/common.sh                    # logging, colour, sudo detection
lib/wifi.sh
lib/dns.sh
lib/bufferbloat.sh
lib/mtu.sh
lib/mtr.sh
lib/ipv6.sh
lib/vpn.sh
lib/tcp_reach.sh
lib/ntp.sh
lib/baseline.sh
lib/watch.sh                     # --watch loop
lib/summary.sh                   # --summary aggregation
lib/launch_agent.plist.tmpl      # --install-watcher template
lib/diagnosis.sh
helpers/*.py                     # if/when heavy parsing moves here
```

## Parallelism

Independent checks run as background jobs. The orchestrator waits on them via
`wait` and reads per-check output back via temp files (`mktemp -d` per run).
Target: full run ≤ 30 s on a healthy network, `--quick` ≤ 8 s.
