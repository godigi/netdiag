# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-05-30

The "architecture + NAT/WAN topology" release. `bin/netdiag` was a single
1238-line bash file in v0.2.x; this release splits it into 23 modules
under `lib/`, adds a parallel-launch helper so independent checks run
concurrently, introduces a `with_timeout` wrapper to keep any one probe
from blocking the whole run, and ships a new NAT / WAN topology section
covering dual-WAN, double-NAT, and UPnP/NAT-PMP status.

### Added

- **Modular layout (lib/\*.sh).** Each section is its own module with a
  documented "Reads / Writes / Entry" header. `bin/netdiag` is now a
  ~230-line orchestrator. `lib/common.sh` holds shared printing,
  diagnosis accumulator, timeout wrapper, and parallel-launch helpers;
  `lib/globals.sh` centralises every cross-module variable.
- **Parallel batch.** DNS, IPv6, TCP reach, NTP, WiFi neighborhood,
  WiFi disconnect history, dual-WAN probe, and UPnP probe now run as
  background jobs collected via a fan-in helper. Per-section stdout is
  buffered so output order stays canonical even though execution is
  concurrent. On this Starlink link the parallel batch is bound by
  `system_profiler SPAirPortDataType` (~15 s); the previously-sequential
  work that used to fill that window is now overlapped.
- **`with_timeout SECS cmd…` helper.** macOS has no `timeout(1)`; this
  is a small shell wrapper that kills the wrapped command after SECS
  and returns 124 on timeout (matches GNU `timeout`). Applied to DNS
  `dig`, TCP `nc`, `traceroute`, `mtr`, and `sntp`.
- **NAT / WAN topology section** (`lib/wan.sh`, ~215 LOC):
  - **WAN-1 / WAN-1b — dual-WAN / load-balancing probe.** Three
    parallel `curl -s https://ifconfig.co/json` requests; flags if
    they return more than one distinct ASN or more than one public IP
    within the same ASN. Surfaces "outbound is being load-balanced
    across N ISPs" as a `warn` (or single-ASN multi-IP as `info` —
    likely CGNAT round-robin).
  - **NAT-1 — double-NAT detection.** Walks the traceroute output and
    counts consecutive RFC1918 hops before the first CGNAT or public
    address. > 1 → `warn` with the chain printed. Pure parse; no extra
    network call.
  - **UP-1 — UPnP / NAT-PMP status.** Prefers Homebrew `miniupnpc`
    (`upnpc -s`); falls back to a raw SSDP M-SEARCH via `nc -u`, then a
    NAT-PMP probe to gateway:5351. Reports `enabled` / `disabled` /
    `unknown`; `info` severity (disabled is the safer default but
    games / Plex / Steam often need it).
  - **JSON schema additions** — new top-level `wan` object with
    `load_balancing.{distinct_asns,distinct_ips,active}`,
    `double_nat.{detected,rfc1918_chain}`, and
    `upnp.{state,device,url,tested_via}`. Additive only; v0.2.x
    consumers see the same other keys.
- **Bats fixtures + parser unit tests** (`tests/test_parse.bats`).
  24 tests covering `grade_bufferbloat` thresholds, traceroute
  parser (`*` skip + banner skip + renumbering), mtr first-lossy-hop
  detection, ARP duplicate detection (with synthetic `arp_dup.txt`),
  DHCP lease-end date math, PMTU computation, and the new double-NAT
  RFC1918 chain walker. Fixtures captured from this Mac
  (`tests/fixtures/{wdutil_info,ipconfig_getsummary,traceroute,arp_an,
  system_profiler}.txt`) are sanitized — MACs, SSIDs, BSSIDs replaced
  with synthetic values.
- **`tests/integration_sudo.sh`** — interactive one-shot that asks for
  sudo once, then exercises the mtr-under-sudo branch end-to-end
  (`bats` can't drive sudo so this lives outside the suite).

### Fixed

- **`traceroute -n` parser dropped hop 1.** The awk skipped NR=1
  expecting a banner, but macOS writes the "traceroute to ..." banner
  to stderr and netdiag was redirecting stderr — so NR=1 was actually
  hop 1. Now matches on `$1 == "traceroute"` so it skips the banner
  only when it's actually present. This v0.2.x bug was latent because
  no v0.2 rule walked the trace data; the new NAT-1 rule surfaced it.
- **`with_timeout` orphaned `sleep` could pin command substitution.**
  The killer subshell's `sleep` inherited stdout, so `$(with_timeout
  ...)` would block for the full timeout even after the wrapped
  command had completed. Killer subshell output now goes to /dev/null.

### Changed

- **JSON `version` is now `"0.3.0"`** (was `"0.2.0"` — the
  `emit_json.py` default).

## [0.2.1] - 2026-05-30

Bugfix release driven by a 13-test pass of v0.2.0 on a real Starlink link.
Surfaced spec violations (exit codes, JSON schema), broken budgets (full
run > 30 s, `--quick` > 8 s under `--quiet`, `--quick TARGET` > 24 s), and
a noisy WiFi-disconnect counter. All fixed; no new features.

### Fixed

- **Exit codes per spec (`0`/`1`/`2`/`3`).** Each diagnosis is now tagged
  `info` / `warn` / `critical` via a new `add_diag` helper that updates
  a `MAX_SEVERITY` global. The script `exit "$MAX_SEVERITY"` at the end.
  Previously every run exited 0 regardless.
- **JSON output now matches `netdiag-prompt.md`'s schema** — top-level
  keys in the spec's order, full `traceroute.{target,hops[]}`,
  `per_hop[]`, `mtr.{target,duration_s,hops[],first_lossy_hop}`,
  `baseline.{compared_runs,regressions[]}`, and
  `most_likely_root_cause` fields. Non-spec extras (`arp_gw_incomplete`,
  `target`, `target_ping`, target traceroute) moved under `netdiag_extras`.
- **WiFi disconnect count over-counted ~3×** because the regex caught
  `disassoc=` substrings inside airportd dictionary dumps. Tightened to
  `disassociated|deauthenticated|link[[:space:]]+down|disconnect[[:space:]]+reason|reassociating`.
- **30 s budget**: full run (parallelised per-hop fallback loop) dropped
  from 32.6 s to ~27.6 s on this Starlink link.
- **8 s `--quick` budget**: `--quick` now also gates WiFi disconnect
  history and the optional `TARGET` traceroute. `--quick` → 7.3 s;
  `--quick TARGET` → 5.5 s (was 24.4 s).
- **Diagnosis ordering** is now severity-descending (critical → warn →
  info), preserving insertion order within each tier. The first emitted
  line is surfaced as `most_likely_root_cause` in the JSON.
- **`--watch` UX**: SIGINT/SIGTERM trap prints "stopped after N
  iteration(s)" and points at the baseline file. Child invocations get
  a new internal `--watch-child` flag that suppresses the per-iteration
  "Report saved to" line.
- **Diagnosis text rendering** now matches the severity: critical fires
  red `✗`, warn fires yellow `⚠`, info fires gray `·` (was always red).
- **PMTU rule split** into critical (< 1400) vs warn (< 1500), reflecting
  the real severity gradient.

## [0.2.0] - 2026-05-30

The full 14-enhancement build out from `netdiag-prompt.md`, plus JSON
output, the continuous-monitoring trio (--watch / --summary /
--install-watcher), and a baseline-regression detector.

### Added — diagnostic checks

- **Bufferbloat** (feature 1): 10 s / 100 MB curl from
  `speed.cloudflare.com` saturates the link while
  ping samples to the gateway and `1.1.1.1` produce a Waveform/DSLReports
  A–F grade per side. Diagnoses B1 (router SQM) and B2 (ISP CPE) split
  the blame.
- **PMTU black-hole probe** (feature 2): walks DF-set ping payloads
  downward to find the largest that gets through; flags effective MTU
  < 1500 (rule M1).
- **mtr continuous loss** (feature 3): `mtr -j -c 60 -i 0.2` parsed via
  `jq` to identify the first hop with > 2 % loss (rule MT1). Falls back
  to the original per-hop loop when mtr / jq / sudo isn't available.
- **IPv6 parity** (feature 4): global v6, gateway, ping6, AAAA,
  traceroute6 hop count, TCP/443 to `ipv6.google.com`. Rule V6-1 fires
  on v6-broken-while-v4-works (Happy Eyeballs masks it).
- **VPN detection** (feature 5): `scutil --nc list`, `tailscale status`,
  default-route via utun*/wg*. Surfaced at top via rule VPN-1.
- **TCP reach panel** (feature 6): parallel `nc -G 3 -z` to a 5-host
  panel + TARGET:443; rule TCP-1 flags "ICMP filtered, TCP fine."
- **WiFi neighbourhood** (feature 7): `system_profiler
  SPAirPortDataType -detailLevel full` channel utilisation. Rule WS-1
  fires when > 3 neighbours share the current channel.
- **WiFi disconnect history** (feature 8): `log show --predicate
  'subsystem CONTAINS[c] "wifi" OR "airport"' --last 1h`; rule WD-1
  on > 3 disconnects in window.
- **Speed test** (feature 9): opt-in `--speed`. Tries Ookla `speedtest`
  first, falls back to open-source `speedtest-cli`. Both go through `jq`.
- **NTP drift** (feature 10): `sntp -t 3 time.apple.com`; rule NT-1 at
  |drift| > 30 s (TLS handshakes start failing).
- **Baseline diff** (feature 11): every run appends to
  `~/net-diag/baseline.jsonl`; current snapshot compared against the
  median of the last 10. Regressions tagged spike / drop / drift /
  change and surfaced as additional diagnoses.
- **Custom TARGET** (feature 12): `netdiag github.com` adds the host to
  DNS, TCP-reach, traceroute, and a dedicated ping.
- **Duplicate-IP / ARP** (feature 13): rule DI-1 on duplicates or
  `(incomplete)` gateway entry.
- **DHCP lease detail** (feature 14): server, lease window, time
  remaining, DHCP-handed DNS. Rules DH-1 (lease expires within 1 h)
  and DH-2 (DHCP DNS ≠ system resolver).

### Added — output and operation

- `--json` emits one schema-conformant JSON object on stdout
  (helpers/emit_json.py). Suppresses human output unless `--log PATH`
  is also passed.
- `--quiet` shows only the Diagnosis section + final report line.
- `--log PATH` overrides the default `~/net-diag/<timestamp>.log`.
- `--baseline` / `--no-baseline` control the comparison + history append.
- `--watch[=SEC]` runs every SEC seconds in the foreground.
- `--summary[=HOURS]` aggregates `baseline.jsonl` into a human report
  (helpers/summary.py).
- `--install-watcher` / `--uninstall-watcher` drop a launchd plist that
  runs netdiag every 15 min in the background.
- `--no-bufferbloat` opts out of the bandwidth-heavy probe on metered
  links.

### Added — packaging

- Requires bash 5 (Homebrew). `bin/netdiag` re-execs under
  `/opt/homebrew/bin/bash` or `/usr/local/bin/bash`, fails clean with
  install hint if neither is present. `install.sh` learns
  `brew install bash` when missing.
- Two Python helpers: `helpers/emit_json.py`, `helpers/baseline.py`,
  `helpers/summary.py`. Stock /usr/bin/python3 on macOS 14+; no extra
  packages.
- `docs/ARCHITECTURE.md` records the bash/Python split.
- `docs/DIAGNOSIS-RULES.md` documents every rule with rationale.
- `examples/sample-output.{txt,json}` captured from a live Starlink run
  (SSID/BSSID/public IP redacted).

### Changed

- Help block moved off the fragile `sed -n '2,10p'` extraction to a
  heredoc that survives future inserts above.
- Argument parser is strict about unknown `--*` flags (silently
  accepting was masking typos).

## [0.1.0] - 2026-05-30

Initial repo skeleton — the 297-line starter script wrapped in proper
repo structure, MIT licence, and GitHub Actions CI for `shellcheck`
(Ubuntu) and `bats-core` (macOS).
