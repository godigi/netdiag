# Architecture

> Status: skeleton. Filled in as the script grows past ~700 bash lines and the
> bash-vs-Python split decision becomes load-bearing.

## Current shape (v0.1.0)

Single bash entry point at `bin/netdiag`. ~300 lines. No modules yet.

## Bash vs Python helper — decision

TBD. The decision will be recorded here once the script approaches ~700 lines
of bash or once a check requires parsing structured output (`mtr` report,
`wdutil` info, `log show` events) that becomes painful in awk/sed.

Candidate heavy parsers that may move to `helpers/*.py`:

- `mtr -r -c 60` report → per-hop loss + RTT stats
- `log show --predicate '...'` → WiFi disconnect / roam timeline
- `~/net-diag/*.{log,json}` baseline aggregation for `--summary`

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
