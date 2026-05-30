# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
