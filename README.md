# netdiag

> Comprehensive network diagnostic CLI for macOS — finds the root cause of
> internet problems in one run instead of forcing you to chain eight commands.

`netdiag` runs a battery of macOS-native checks (interface, WiFi, gateway,
DNS, traceroute, bufferbloat, PMTU, mtr, IPv6, VPN, TCP reach, WiFi scan +
disconnect history, NTP drift, ARP, DHCP, plus NAT/WAN topology — dual-WAN,
double-NAT, UPnP/NAT-PMP), writes a timestamped JSON + human log, then
prints a **Diagnosis** section that names a likely culprit with evidence
and a recommendation. It also tracks a rolling baseline so intermittent
regressions ("WiFi RSSI dropped from -55 to -78 since yesterday", "gateway
RTT is 4× the 30-day median") get caught the next time you run it.

Independent probes run as parallel background jobs, so a typical full
run finishes well inside the spec's 30 s budget on a healthy link.

## Why

When the internet is flaky you don't have time to run `ping`, `traceroute`,
`dig`, `ipconfig`, `wdutil`, `mtr`, `system_profiler`, and `speedtest`
separately and correlate the outputs by hand. `netdiag` does that and tells
you where to look first. For *intermittent* problems — where the failure
window is gone by the time you can investigate — `netdiag --watch` or the
`--install-watcher` LaunchAgent runs it on a cron so the baseline catches
the regression on the next pass.

## Install

```sh
git clone https://github.com/godigi/netdiag.git
cd netdiag
./install.sh
```

`install.sh` symlinks `bin/netdiag` into `/usr/local/bin` (or `~/bin` if
the system prefix isn't writable) and runs `brew install bash` if it
needs to. Pass `--prefix DIR` to override the install location;
`--no-brew` to skip the bash bootstrap.

A Homebrew tap and a `curl | bash` one-liner are still on the roadmap.

## Usage

```
netdiag [TARGET] [--quick] [--gping] [--no-bufferbloat] [--speed]
                 [--json] [--quiet] [--log PATH]
                 [--baseline | --no-baseline]
netdiag --watch[=SEC]            # foreground loop, every SEC (default 300)
netdiag --summary[=HOURS]        # aggregate ~/net-diag/baseline.jsonl
netdiag --install-watcher        # launchd plist, every 15 min, background
netdiag --uninstall-watcher
```

| Flag                 | Effect                                                 |
|----------------------|--------------------------------------------------------|
| `TARGET`             | host added to ping, DNS, TCP, and a 2nd traceroute     |
| `--quick`            | skip bufferbloat, mtr, speed test, WiFi scan           |
| `--expert`           | show every detailed measurement section (RSSI, full    |
|                      | DNS / TCP / traceroute / DHCP / per-hop loss). Default |
|                      | is a compact Report card + diagnoses only.             |
| `--gping`            | launch live ping monitor on the discovered hops at end |
| `--no-gping`         | skip the gping prompt (scripts / watchers)             |
| `--no-bufferbloat`   | skip the 100 MB / 10 s probe (metered link)            |
| `--speed`            | run a speedtest (~30 s, ~50 MB)                        |
| `--json`             | emit schema-conformant JSON on stdout                  |
| `--quiet`            | only the Diagnosis section is printed                  |
| `--log PATH`         | override the default `~/net-diag/<timestamp>.log`      |
| `--no-baseline`      | don't compare to history / don't append to history     |

Examples:

```sh
netdiag                      # full run, human-readable
netdiag --quick              # <8 s subset for "is it up?"
netdiag github.com           # "why is github specifically slow?"
netdiag --json | jq .diagnosis
netdiag --watch=180          # check every 3 min
netdiag --summary=168        # what's been happening this past week?
sudo netdiag                 # unlocks RSSI/noise/channel + mtr per-hop
```

## Sample output

Quoted from [`examples/sample-output.txt`](./examples/sample-output.txt)
(real run on a Starlink link; SSID/BSSID/public IP redacted):

```
── Local network ──
  ✓ Interface: en0   IP: 192.168.50.56   Gateway: 192.168.50.1
── VPN ──
  ✓ No VPN active.
── WiFi ──
  ✓ SSID: <redacted-ssid>  (interface en0)
── Bufferbloat (loaded vs idle latency) ──
  · Loaded: gateway 3.2 ms (+-2.1 ms) · internet 28.6 ms (+1.8 ms)
  ✓ Bufferbloat (gateway): grade A
  ✓ Bufferbloat (internet): grade A
── Path MTU (DF-set probe to 1.1.1.1) ──
  ✓ Effective path MTU: 1500 (full ethernet frames pass DF)
── Diagnosis ──
  ✓ Nothing obviously wrong from these checks.
```

The corresponding JSON is at
[`examples/sample-output.json`](./examples/sample-output.json) and matches
the schema in [`netdiag-prompt.md`](./netdiag-prompt.md).

## Diagnosis rules

Each diagnosis is documented with trigger, severity, evidence,
recommendation, and rationale in
[`docs/DIAGNOSIS-RULES.md`](./docs/DIAGNOSIS-RULES.md). Short list:

- **W1/W2** weak WiFi signal / low SNR
- **G1/G2** gateway loss (with vs without weak WiFi)
- **P1/P2** public unreachable; DNS in/out of play
- **D1** partial DNS, internet reachable
- **B1/B2** bufferbloat at gateway / ISP hop
- **M1** path MTU < 1500
- **MT1** first lossy hop identified
- **V6-1** IPv6 broken while v4 works (Happy Eyeballs masks)
- **VPN-1** VPN carrying the default route
- **TCP-1** TCP works, ICMP filtered
- **WS-1** WiFi channel congested
- **WD-1** WiFi link flapping
- **NT-1** system clock drift > 30 s
- **DI-1** duplicate IP / incomplete gateway ARP
- **DH-1** DHCP lease expires within 1 h
- **DH-2** DHCP DNS ≠ system resolver

## Dependencies

- **Required:** bash 5 (`brew install bash`), and macOS built-ins
  (`ipconfig`, `networksetup`, `route`, `scutil`, `dig`, `traceroute`,
  `ping`, `nc`, `arp`, `system_profiler`, `sntp`, `curl`, `log`).
- **Optional (Homebrew):** `jq` (required for `--json`, mtr parse,
  Ookla/CLI speedtest parse), `mtr` (richer per-hop loss), `gping`
  (live monitoring on exit), `speedtest` (Ookla) or `speedtest-cli`.
- **Bundled Python helpers** use stock `/usr/bin/python3` only — no extra
  packages.

Missing optional deps degrade gracefully with a one-line install hint.

## Permissions

Sudo-free by default. `sudo netdiag` unlocks:

- Rich WiFi metrics via `wdutil info` (RSSI, noise, channel, PHY, tx rate)
- `mtr` per-hop loss (raw sockets need root)
- `systemsetup -getusingnetworktime` / `-getnetworktimeserver`

The script uses `sudo -n` for these — if creds aren't cached it skips
with a hint, never prompts mid-run.

## Continuous monitoring

For intermittent problems, run on a schedule:

```sh
netdiag --install-watcher    # launchd, every 15 min
# ... later ...
netdiag --summary=168        # what happened this past week?
```

`baseline.jsonl` is append-only at `~/net-diag/baseline.jsonl`; pipe it
through `jq` for ad-hoc analysis.

## JSON mode

```sh
netdiag --json | jq '.bufferbloat'
{
  "idle_gw_rtt_ms": 5.4,
  "loaded_gw_rtt_ms": 4.5,
  "gw_grade": "A",
  "inet_grade": "B",
  ...
}
```

Full schema in [`netdiag-prompt.md`](./netdiag-prompt.md). Sample at
[`examples/sample-output.json`](./examples/sample-output.json).

## Roadmap

v0.3:

- Refactor into `lib/*.sh` modules (currently single-file at ~1300 lines)
- Diagnosis ranking (severity × confidence, `most_likely_root_cause`)
- Apple Private Relay detection
- Captive-DNS detection (resolver returning A records for `.invalid`)
- Upload-side bufferbloat probe
- Homebrew tap

v0.4+:

- Linux port
- Web UI for `~/net-diag/`
- Slack/Discord webhook on critical diagnosis
- iperf3 to user-provided server for LAN throughput

## Contributing

`shellcheck` runs on every push (`.github/workflows/shellcheck.yml`).
`bats-core` smoke tests run on `macos-latest`
(`.github/workflows/bats.yml`). Run locally:

```sh
brew install shellcheck bats-core jq
shellcheck bin/netdiag install.sh
bats tests/
```

Conventional commits preferred; one logical change per PR; samples
must come from real runs (with personal info redacted).

## License

[MIT](./LICENSE).
