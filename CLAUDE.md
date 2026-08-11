# netdiag — project instructions

This project builds `netdiag`, a comprehensive macOS network-diagnostic CLI. This file is the working contract; the reference docs are [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md), [`docs/DIAGNOSIS-RULES.md`](./docs/DIAGNOSIS-RULES.md), and [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Scope

Grown from a ~300-line bash starter into a modular `lib/*.sh` CLI with 14 diagnostic enhancements, shipped as a public GitHub repo with CI and a one-line installer. The original build spec (`netdiag-prompt.md`) was removed once its two load-bearing sections — the JSON schema and the acceptance criteria — had been moved into `docs/JSON-SCHEMA.md` and this file. It remains in git history.

## Engineering constraints (non-negotiable)

- **Platform:** macOS 14+ (Sonoma/Sequoia/Tahoe), Apple Silicon and Intel. No Linux portability for v1.
- **Shell:** must work under both zsh (default) and Homebrew bash 5+. Declare bash in the shebang if needed.
- **Dependencies:** prefer macOS built-ins (`ipconfig`, `networksetup`, `route`, `scutil`, `wdutil`, `dig`, `traceroute`, `ping`, `nc`, `arp`, `log`, `sntp`, `system_profiler`, `curl`). Acceptable Homebrew extras: `mtr`, `gping`, `speedtest` (or `speedtest-cli`), `jq`. Detect missing deps → skip with hint, never hard-fail.
- **Permissions:** default run is sudo-free. sudo-only checks must try `sudo -n` first, degrade gracefully, never prompt mid-run.
- **Parallelism:** run independent checks concurrently via background jobs + `wait`. Target ≤ 35s for `--no-speed`, ≤ 8s `--quick`. A default run now includes the speed test and is bound by whichever speedtest CLI is installed — measured at ~115s with `speedtest-cli` and ~65s with Ookla's `speedtest`, which is why the installer prefers Ookla. `--no-speed` is the flag to reach for when the run needs to be fast.
  - Two checks must **not** be parallelised, because both measure a property of a quiet link: `internet_ping_run` (packet loss / latency) and `bufferbloat_run` (which saturates the link deliberately). Running the loss probe inside the parallel batch made it report 30% loss on a healthy network.
- **Read-only:** never modify routing, DNS, WiFi, or ARP state.
- **shellcheck-clean** at default severity. `# shellcheck disable=...` only with justification.
- **Thresholds live in `lib/thresholds.sh`, nowhere else.** Two things now
  judge a network — `lib/diagnosis.sh` (one verdict per scan) and
  `lib/monitor.sh` (one every few seconds) — and if they drift the app
  shows a green dot over a red report. `tests/test_thresholds.bats` fails
  the build on an inline numeric cutoff in either file.
- **The GUI holds no diagnostic logic.** `gui/` renders what the CLI
  decides: rule IDs come from `status.rules`, prose comes from
  `diagnosis[].summary` verbatim. If a change would put a threshold or a
  user-facing verdict string into Swift, it belongs in `lib/` instead.

## CLI surface

```
netdiag [TARGET] [--quick] [--quiet] [--json] [--expert] [--redact]
        [--gping] [--no-gping] [--no-bufferbloat]
        [--speed] [--no-speed] [--mtu-only] [--wifi-only]
        [--baseline] [--no-baseline] [--log PATH] [-h|--help]
netdiag --watch[=SEC] | --summary[=HOURS] | --history[=N]
netdiag --monitor [--monitor-fast-interval SEC] [--monitor-degraded-interval SEC]
                  [--monitor-medium-interval SEC] [--monitor-slow-interval SEC]
                  [--monitor-count N]
netdiag --install-watcher | --uninstall-watcher
```

`--history` and `--monitor` exist for the GUI (see below) but are ordinary
CLI surface: both are documented in `docs/JSON-SCHEMA.md`, both are covered
by bats, and neither requires the app.

`--monitor` is the machine-readable sibling of `--watch`, not a duplicate
of it: `--watch` re-runs `--quick` and prints prose for a person, while
`--monitor` streams one compact JSON object per line for a program, writes
nothing to disk, and probes on three cadence tiers instead of one. It is
paused with `SIGUSR1` and resumed with `SIGUSR2` — **never `SIGSTOP`**, see
the header of `lib/monitor.sh` for the orphaned-process-group reason.

## Output modes

- **Default:** colored human-readable stdout + ANSI-stripped log to `~/net-diag/<timestamp>.log`.
- **`--json`:** single JSON object to stdout matching [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md). No colors, no log unless `--log` also passed.
- **`--quiet`:** only the Diagnosis section to stdout (full log still written).
- **`--quick`:** skip bufferbloat, mtr, speed test, internet packet-loss probe, baseline diff, WiFi scan. An explicit `--speed` overrides the speed-test skip.

## Exit codes

- `0` healthy · `1` warnings only · `2` ≥ 1 critical diagnosis · `3` script error.
- Usage errors (bad flag, duplicate TARGET, bare `--log`) exit `3`, not `2` —
  `2` is reserved for a real diagnosis so wrappers can distinguish the two.

## The 14 enhancements (implementation order)

**High-value:** 1) bufferbloat (loaded vs idle RTT, A–F grade, gateway vs ISP split) · 2) PMTU black-hole probe · 3) continuous loss via `mtr -r -c 60` · 4) IPv6 parity · 5) VPN-active detection · 6) TCP reach panel (not just ICMP).

**Medium-value:** 7) WiFi neighborhood scan · 8) WiFi disconnect/roam history from `log show` · 9) speed test (Ookla → speedtest-cli → skip) · 10) NTP/time-sync drift check · 11) baseline diff against last N runs · 12) custom positional `TARGET` argument.

**Polish:** 13) duplicate-IP / ARP conflict detection · 14) DHCP lease detail + DHCP-vs-system DNS comparison.

Each must: produce a labeled section, contribute to JSON output, feed the Diagnosis stage where appropriate.

## Repo layout

```
netdiag/
├── bin/netdiag              # bash entry point
├── lib/*.sh                 # modular checks if splitting bash
├── helpers/*.py             # Python helpers if porting parse logic
├── tests/{fixtures,*.bats}  # bats-core
├── examples/sample-output.{txt,json}
├── gui/                     # SwiftUI menu-bar app (SwiftPM, no Xcode)
│   ├── Package.swift  Makefile  Resources/Info.plist
│   └── Sources/NetdiagGUI/{Models,Services,Alerts,Views,Support}
├── docs/{ARCHITECTURE,DIAGNOSIS-RULES,JSON-SCHEMA}.md
├── .github/workflows/{shellcheck,bats}.yml
├── README.md  CHANGELOG.md  LICENSE  install.sh  .gitignore
```

Before refactoring past ~700 lines of bash, decide bash-modules vs bash+Python helper and record the rationale in `docs/ARCHITECTURE.md`.

## Workflow expectations

1. Before writing code for a new chunk of work, produce a short plan (< 400 words) covering structure, bash/Python split, implementation order, and clarifying questions.
2. After implementing, actually run `netdiag` on this machine and paste real output into `examples/sample-output.{txt,json}`. If running in a sandbox, say so explicitly.
3. Commits: one per logical feature group, clean history. Tag releases `v0.2.0+`.
4. Don't push to GitHub or create the repo until the script runs and sample output looks sane.

## Acceptance criteria (definition of done)

All 11 must hold before declaring the project shippable:

1. `netdiag` runs end-to-end on macOS with all 14 sections, no shellcheck warnings, no uncaught errors.
2. `netdiag --json` produces valid JSON matching `docs/JSON-SCHEMA.md`; `netdiag --json | jq .` succeeds.
3. `netdiag --quick` skips bufferbloat, mtr, speed test, baseline diff, and WiFi scan; finishes in ≤ 8 s on a healthy network.
4. `sudo netdiag` adds RSSI/noise/channel/PHY/tx_rate to the WiFi section and to the neighborhood scan.
5. `netdiag github.com` adds the target to ping, traceroute, TCP-reach, and DNS.
6. Exit codes work as specified (0/1/2/3).
7. A successful run writes a parseable human-readable log to `~/net-diag/<timestamp>.log`.
8. Each diagnosis explains its conclusion with evidence, not just a verdict.
9. README is complete; `examples/sample-output.{txt,json}` are real captures from an actual run.
10. The repo is public on GitHub, tagged, with passing CI (shellcheck + bats).
11. `docs/ARCHITECTURE.md` explains the bash-vs-Python decision; `docs/DIAGNOSIS-RULES.md` lists every diagnosis rule that can fire.
