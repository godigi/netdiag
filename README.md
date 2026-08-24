# netdiag

[![shellcheck](https://github.com/godigi/netdiag/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/godigi/netdiag/actions/workflows/shellcheck.yml)
[![bats](https://github.com/godigi/netdiag/actions/workflows/bats.yml/badge.svg)](https://github.com/godigi/netdiag/actions/workflows/bats.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)](#requirements)

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

Independent probes run as parallel background jobs. A default run is
bound by the speed test — about 55 s with Ookla's `speedtest`, roughly
twice that with the `speedtest-cli` fallback, which is why the installer
prefers Ookla. `--no-speed` brings it under 35 s and `--quick` under 8 s.
Pass `--progress` (or use the app) to watch each check land rather than
a spinner.

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
curl -fsSL https://raw.githubusercontent.com/godigi/netdiag/main/install.sh | bash
```

Then run `netdiag`.

That fetches netdiag into `~/.local/share/netdiag`, puts a `netdiag`
symlink on your PATH, and installs Homebrew's bash 5 if you don't have it
(macOS ships bash 3.2, which netdiag can't run on). Re-running the same
command updates an existing install via `git pull`.

If you'd rather read the script before piping it to a shell — a reasonable
habit — clone instead:

```sh
git clone https://github.com/godigi/netdiag.git
cd netdiag
./install.sh
```

Run from inside a clone, `install.sh` points the symlink at that clone and
never touches the network.

<details>
<summary>Options and uninstall</summary>

```sh
install.sh --prefix DIR    # where to put the symlink
                           # default: /usr/local/bin if writable, else ~/bin
install.sh --no-brew       # skip the bash 5 bootstrap
install.sh --uninstall     # remove the symlink; keeps the checkout and ~/net-diag
```

When piping, flags go after `-s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/godigi/netdiag/main/install.sh \
  | bash -s -- --prefix ~/.local/bin
```

`NETDIAG_SRC` overrides the checkout location, `NETDIAG_REPO` the clone URL.

To remove netdiag entirely:

```sh
netdiag --uninstall-watcher            # if you installed the LaunchAgent
~/.local/share/netdiag/install.sh --uninstall
rm -rf ~/.local/share/netdiag ~/net-diag
```

</details>

### Requirements

macOS 14+ on Apple Silicon or Intel, plus bash 5 (the installer handles
it). A Homebrew tap is still on the roadmap.

## Usage

```
netdiag [TARGET] [--quick] [--gping] [--no-bufferbloat] [--speed]
                 [--json] [--quiet] [--expert] [--log PATH] [--progress]
                 [--baseline | --no-baseline]
netdiag --mtu-only               # just the path-MTU probe
netdiag --wifi-only              # just the WiFi checks
netdiag --speed-only             # just the speed test, recorded to history
netdiag --dns-only               # just DNS and resolver checks
netdiag --bufferbloat-only       # just the loaded-vs-idle latency test
netdiag --ping-only              # just gateway and internet latency/loss
netdiag --redact --json          # safe to paste into a ticket
netdiag --watch[=SEC]            # foreground loop, every SEC (default 300)
netdiag --monitor                # streaming JSONL, one sample per line
netdiag --summary[=HOURS]        # aggregate ~/net-diag/baseline.jsonl
netdiag --history[=N]            # whole run store as network-grouped JSON
netdiag --show=ID                # one stored run, judged against its network
netdiag --install-watcher        # launchd plist, every 15 min, background
netdiag --uninstall-watcher
netdiag --version                # print the version and exit
netdiag --capabilities           # JSON handshake: schemas, features, deps
netdiag --rules-catalog          # JSON catalog: every rule ID, title, blurb
```

| Flag                 | Effect                                                 |
|----------------------|--------------------------------------------------------|
| `TARGET`             | host added to ping, DNS, TCP, and a 2nd traceroute     |
| `--quick`            | skip bufferbloat, mtr, speed test, packet-loss probe,  |
|                      | WiFi scan                                              |
| `--expert`           | show every detailed measurement section (RSSI, full    |
|                      | DNS / TCP / traceroute / DHCP / per-hop loss). Default |
|                      | is a compact Report card + diagnoses only.             |
| `--gping`            | launch live ping monitor on the discovered hops at end |
| `--no-gping`         | skip the gping prompt (scripts / watchers)             |
| `--no-bufferbloat`   | skip the 100 MB / 10 s probe (metered link)            |
| `--speed`            | run the speedtest even under `--quick` (it is already  |
|                      | on by default in a normal run)                         |
| `--no-speed`         | skip the speedtest — metered links, or to bring a full |
|                      | run back under ~35 s                                   |
| `--json`             | emit schema-conformant JSON on stdout                  |
| `--quiet`            | only the Diagnosis section is printed                  |
| `--log PATH`         | override the default `~/net-diag/<timestamp>.log`      |
| `--no-baseline`      | don't compare to history / don't append to history     |
| `--redact`           | mask identifying values on stdout / JSON (see below)   |
| `--mtu-only`         | run only the path-MTU probe and its prerequisites      |
| `--wifi-only`        | run only link quality, neighbourhood scan, disconnects |
| `--speed-only`       | run only the speed test; recorded as a `speed-only`    |
|                      | run, so it contributes its number without counting as  |
|                      | a health check                                         |
| `--dns-only`         | run only DNS and resolver checks                       |
| `--bufferbloat-only` | run only the loaded-vs-idle latency test               |
| `--ping-only`        | run only gateway and internet latency/loss probes      |
| `--progress`         | emit progress events on **fd 3** while the run happens |
| `--monitor`          | stream one compact JSON object per line until stopped  |
| `--history[=N]`      | emit the whole run store as one grouped JSON object    |
| `--show=ID`          | one stored run in full, plus how each of its metrics   |
|                      | compares to every other run on the same network        |
| `--version`          | print `netdiag VERSION` and exit                       |
| `--capabilities`     | one JSON object describing this install: per-mode      |
|                      | schema numbers, a feature list, and which optional     |
|                      | dependencies are on `PATH`                             |
| `--rules-catalog`    | one JSON object cataloguing every diagnosis-engine and |
|                      | monitor rule: title, category, severity, scope, a      |
|                      | plain-English blurb, and a `docs/DIAGNOSIS-RULES.md`   |
|                      | anchor                                                 |

Examples:

```sh
netdiag                      # full run, human-readable
netdiag --quick              # <8 s subset for "is it up?"
netdiag github.com           # "why is github specifically slow?"
netdiag --json | jq .diagnosis
netdiag --watch=180          # check every 3 min
netdiag --summary=168        # what's been happening this past week?
netdiag --wifi-only          # "is it the WiFi?" without the full battery
netdiag --redact             # before pasting output into a forum thread
netdiag --monitor | jq -c .status    # watch the rules a program would see
netdiag --history | jq .networks     # which networks have I been on?
netdiag --speed-only         # "how fast is it *right now*?"
sudo netdiag                 # unlocks RSSI/noise/channel + mtr per-hop
```

### Watching a run happen

A default run takes about a minute. `--progress` reports what it is doing
while it does it, as one JSON object per line on **file descriptor 3**:

```sh
netdiag --progress 3>&1 >/dev/null | jq -c 'select(.t=="phase")'
{"t":"phase","name":"gateway","state":"start"}
{"t":"phase","name":"gateway","state":"done","rc":0,"ms":2043}
{"t":"phase","name":"wifi_scan","state":"skip","why":"not on wifi"}
```

fd 3 rather than stdout, which stays exactly one JSON object under
`--json`, and rather than stderr, which is captured per-check while the
parallel batch runs and so would not surface until each check finished.
A `plan` event first names the phases the mode will attempt; there is no
percentage, because `--json` produces nothing until the end and there
would be nothing for a percentage to be a percentage *of*.

Without the flag, fd 3 is not written to at all.

### Reading past runs

`~/net-diag/baseline.jsonl` keeps the complete JSON of every run.
`--history` lists them and `--show` opens one, scored against every other
run on the same network:

```sh
netdiag --history | jq -r '.runs[0].id'
2026-08-12T00:15:37Z.a4f81c02
netdiag --show=2026-08-12T00:15:37Z.a4f81c02 | jq -r '.comparison.metrics.gateway_rtt_ms.summary'
7.6 ms — typical for this network (median 4.6 ms across 1,913 checks).
```

An id is the timestamp plus eight hex of the record's content hash. A
timestamp alone will not do: two runs can finish in the same second, and
in a real store they do.

### Sharing a report

A netdiag report carries your public IP, SSID, BSSID, IPv6 address,
gateway MAC and city — all of which end up in a forum thread if you paste
it unedited. `--redact` masks them:

```sh
netdiag --redact             # stdout is safe to paste
netdiag --redact --json      # same, machine-readable
```

ASN and ISP name are deliberately **kept** — they identify a provider, not
a person, and they're needed to reason about the fault. Private (RFC1918)
addresses are kept too: `192.168.1.1` says nothing about you, and blanking
it would gut the NAT and ARP sections.

The log file written to `~/net-diag/` always keeps full detail. It lives on
your machine; only what you share gets masked. `--redact` implies compact
output, because section bodies stream out before every value that needs
masking has been discovered.

### Retention

`~/net-diag/` is capped: the newest 200 `.log` files and the newest 2000
`baseline.jsonl` records are kept, pruned at the end of each run. Override
with `NETDIAG_KEEP_LOGS` / `NETDIAG_KEEP_HISTORY` (`0` disables pruning).
This matters most with `--install-watcher`, which otherwise adds 96 logs
and 96 history records a day, forever.

### Baselines are per-network

Regression comparisons are scoped to the network you're on, identified by
gateway MAC, then SSID, then gateway IP. Without that, a laptop moving
between home, office and a café reported "gateway RTT x4 spike" and "ISP
changed" on every move. Runs recorded before v0.5.0 have no network
identity and are skipped rather than pooled in.

### Exit codes

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| `0`  | healthy — no diagnoses                                             |
| `1`  | warnings only                                                      |
| `2`  | at least one critical diagnosis                                    |
| `3`  | script error — bad flag, missing bash 5, or an unexpected abort    |

Usage errors exit `3`, never `2`: a wrapper checking for `2` should be
paged for a broken network, not for a typo in its own arguments.

## Sample output

The default run is a compact Report card plus plain-English findings —
no jargon, and each finding says what it means for you and what to do.
Abridged from [`examples/sample-output.txt`](./examples/sample-output.txt),
a real `netdiag --redact` run:

```
── Report ──
  ⚠  Packet size         1480 bytes · below standard · some sites may hang
  ⚠  WiFi channel        crowded · 6 neighbouring networks

  ✓  Network             en0 · WiFi 5GHz ch52
  ✓  Router              192.168.15.1 · 0% loss · 7.6 ms · ±4.3 ms jitter
  ✓  Internet            TELEFONICA BRASIL S.A ([redacted], Brazil)
  ✓  Latency             1.1.1.1 · 55 ms · ±1.2 ms jitter
  ✓  Packet loss         0.0% to 1.1.1.1 · 0.0% to 8.8.8.8 · clean
  ✓  DNS                 working
  ✓  IPv6                working
  ✓  Bufferbloat         grade A/A · clean under load
  ✓  Router config       UPnP disabled (safer default)
  ✓  Hosts file          clean (only macOS defaults)
  ·  VPN                 not active

── What we found ──
  ⚠ Some websites load fine and others hang forever loading — your network
    is silently dropping packets above 1480 bytes. Usually caused by a
    VPN, a tunneled connection, or a DSL link. Try disconnecting any VPN;
    if it persists, ask your ISP or check your router's WAN-MTU /
    MSS-clamping setting.

  ⚠ Your WiFi channel (52) is shared with 6 neighbouring networks — they
    all interfere with each other. Switch to a less-crowded channel in
    your router's WiFi settings (good 5 GHz choices most routers don't
    pick automatically: 149, 153, 157, 161).

── Speed test ──
  ✓ Down 415.6 Mbps · Up 237.6 Mbps · 7.825 ms (jitter 1.712 ms)
```

`--expert` adds every underlying measurement section (RSSI, full DNS,
TCP, traceroute, DHCP, per-hop loss). The corresponding JSON is at
[`examples/sample-output.json`](./examples/sample-output.json); its shape
is documented in [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md).

## Diagnosis rules

Each diagnosis is documented with trigger, severity, evidence,
recommendation, and rationale in
[`docs/DIAGNOSIS-RULES.md`](./docs/DIAGNOSIS-RULES.md). Short list:

- **N1/N1b** no network at all / router up but nothing public responds
- **W1/W2** weak WiFi signal / low SNR
- **G1/G2** gateway loss (with vs without weak WiFi)
- **P1/P2** public unreachable; DNS in/out of play
- **D1** partial DNS, internet reachable
- **B1/B2** bufferbloat at gateway / ISP hop
- **M1** path MTU < 1500
- **MT1** first lossy hop identified
- **V6-1** IPv6 broken while v4 works (Happy Eyeballs masks)
- **VPN-1** VPN carrying the default route *(specified, not yet emitted)*
- **TCP-1** TCP works, ICMP filtered
- **WS-1** WiFi channel congested
- **WD-1** WiFi link flapping
- **NT-1** system clock drift > 30 s
- **DI-1/DI-2** incomplete gateway ARP / duplicate IP on the LAN
- **DH-1** DHCP lease expires within 1 h
- **DH-2** system resolver manually overrides the DHCP-handed one
- **WAN-1/WAN-1b** traffic split across ISPs / CGNAT round-robin
- **NAT-1/NAT-1b** home-side double-NAT / ISP-side private transit
- **BL-1** a metric regressed against this network's own history

`UP-1` (UPnP enabled) is specified but deliberately not emitted as a
diagnosis — it already has its own Report row, and repeating it here
would say the same thing twice.

## Dependencies

- **Required:** bash 5 (`brew install bash`), and macOS built-ins
  (`ipconfig`, `networksetup`, `route`, `scutil`, `dig`, `traceroute`,
  `ping`, `nc`, `arp`, `system_profiler`, `sntp`, `curl`, `log`).
- **Optional (Homebrew):** `jq` (only enables `mtr`'s sudo-only per-hop
  view and Tailscale's VPN name — `--json`, `--history`, `--monitor` and
  the speed test are all python3-based and run without it), `mtr`
  (richer per-hop loss), `gping` (live monitoring on exit), `speedtest`
  (Ookla) or `speedtest-cli`.
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
through `jq` for ad-hoc analysis. Once it passes its retention cap the
oldest records roll into `baseline-archive.jsonl` rather than being
deleted — `--history` reads both.

### `--watch` vs `--monitor`

Two different tools that both repeat, and it is worth being clear which
you want:

| | `--watch[=SEC]` | `--monitor` |
|---|---|---|
| Audience | a person watching a terminal | a program |
| Output | prose — the Diagnosis section, per iteration | one JSON object per line |
| Work per cycle | a full `--quick` run (~10 s) | one cadence tier (~2 s) |
| Writes | a log file and a history record per run | nothing at all |
| Cadence | one fixed interval | three tiers, adaptive |

`--watch` is for sitting and watching a flaky link. `--monitor` is for
feeding something — it is what [`netdiag.app`](#netdiagapp-menu-bar-monitor)
consumes. Sample shape and signals (`SIGUSR1` pauses, `SIGUSR2` resumes)
are documented in [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md).

## netdiag.app (menu-bar monitor)

A native SwiftUI menu-bar app lives in [`gui/`](./gui). It watches the
connection continuously, notifies in plain English when something breaks,
and keeps every raw measurement one click away.

```sh
make -C gui identity   # once: a stable signing identity (see below)
make -C gui run        # build, bundle, sign, launch
```

**The app is a client, not a second brain.** It holds no thresholds and
writes no diagnosis prose. Every verdict on screen comes from the CLI:
`status.rules` arrives pre-computed from `lib/monitor.sh`, and every
explanatory sentence is a `diagnosis[].summary` rendered verbatim. If a
change would add a number that decides whether something is wrong, or a
sentence explaining a fault, it belongs in `lib/` instead.

Four disclosure layers, so the same app serves a non-technical user and an
expert without asking anyone to declare which they are:

| Layer | Content |
|---|---|
| Menu bar | health dot, country flag, optionally the public IP |
| Dropdown | a one-card stage (healthy / alerted / testing / paused) with the "Check My Connection" button pinned under it, a fixed instrument grid (internet ping, internet loss, download, upload, router, Wi-Fi, VPN, location), a live heartbeat strip, the last 24 hours of changes, and a footer (Open Dashboard, Pause/Resume Monitoring, Settings, Quit) |
| Dashboard | **Status** (report card + diagnosis prose, and the live phase list while a check runs) · **Live** (gateway RTT, internet RTT and router loss over the last hour) · **Activity** (every CLI-reported change and fired alert, newest first) · **History** (charts over every run) · **Networks** (per-network stats, rename, merge, and every stored check) |
| Expert | raw measurements, rule IDs, hop tables, sparklines, raw JSON |

The expert layer is a disclosure whose open/closed state persists — never
a mode chosen at first launch.

Charts draw gaps as gaps. The monitor pauses for system sleep, for
display sleep, and for the whole duration of every scan; a line drawn
straight across a pause would claim measurements that were never taken.
The gap threshold comes from the cadence each sample reports about
itself, so it stays correct when the cadence changes.

**Distribution.** Right now the app is a local build — `make -C gui run`
— and it signs with the self-signed identity described below. Shipping it
to anyone else needs a Developer ID and notarization, which is not done
yet: an unsigned or ad-hoc-signed `.app` downloaded from the internet is
blocked by Gatekeeper and is genuinely hostile to a non-technical user.
Until that lands, build it from a clone.

**Signing.** `make identity` creates a stable self-signed identity in your
keychain (one interactive keychain prompt). This matters more than it
sounds: macOS keys permission grants to the code signature, and `codesign
-s -` produces a new one on every rebuild — which would re-prompt not only
for Location but for **Notifications**, the permission the alert engine
depends on. Without the identity the build still works, signs ad-hoc, and
says so.

Requires macOS 14+ and the Command Line Tools (no Xcode needed).

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

Full schema in [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md). Sample at
[`examples/sample-output.json`](./examples/sample-output.json).

## Roadmap

Shipped: modular `lib/*.sh` (v0.3.0), NAT/WAN topology (v0.3.0),
plain-English diagnoses and the Report card (v0.4.0), per-network
baselines and `--redact` (v0.5.0), a one-line installer (v0.6.0),
packet-loss diagnosis (v0.6.0), `--monitor` / `--history` and the
menu-bar app (v0.7.0), `--show` and run browsing (v0.8.0), `--progress`,
`--speed-only` and the Live tab (v0.9.0), in-app update checks and the
`D3`/`D4`/`V6-2` DNS and IPv6 rules (v0.9.1).

Next:

- Developer ID signing + notarization, so the app can be handed to
  someone who did not build it
- Homebrew tap (`brew install godigi/netdiag/netdiag`)
- Apple Private Relay detection
- Captive-DNS detection (resolver returning A records for `.invalid`)
- Upload-side bufferbloat probe
- Diagnosis confidence scoring, not just severity

Later:

- Linux port
- Web UI for `~/net-diag/`
- Slack/Discord webhook on critical diagnosis
- iperf3 to a user-provided server for LAN throughput

## Contributing

Bug reports and PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).

`shellcheck` runs on every push (`.github/workflows/shellcheck.yml`) and
`bats-core` runs on `macos-latest` (`.github/workflows/bats.yml`).
Run both locally:

```sh
brew install shellcheck bats-core jq
shellcheck bin/netdiag install.sh lib/*.sh
bats tests/
```

## License

[MIT](./LICENSE).
