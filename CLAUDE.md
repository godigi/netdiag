# netdiag — project instructions

This project builds `netdiag`, a comprehensive macOS network-diagnostic CLI. The full specification lives in [`netdiag-prompt.md`](./netdiag-prompt.md) — read it before making non-trivial changes. The summary below is the working contract.

## Scope

Extend a ~300-line bash starter (embedded in `netdiag-prompt.md`) with 14 enhancements, refactor as it grows, and ship it as a GitHub repo with CI and distribution.

## Engineering constraints (non-negotiable)

- **Platform:** macOS 14+ (Sonoma/Sequoia/Tahoe), Apple Silicon and Intel. No Linux portability for v1.
- **Shell:** must work under both zsh (default) and Homebrew bash 5+. Declare bash in the shebang if needed.
- **Dependencies:** prefer macOS built-ins (`ipconfig`, `networksetup`, `route`, `scutil`, `wdutil`, `dig`, `traceroute`, `ping`, `nc`, `arp`, `log`, `sntp`, `system_profiler`, `curl`). Acceptable Homebrew extras: `mtr`, `gping`, `speedtest` (or `speedtest-cli`), `jq`. Detect missing deps → skip with hint, never hard-fail.
- **Permissions:** default run is sudo-free. sudo-only checks must try `sudo -n` first, degrade gracefully, never prompt mid-run.
- **Parallelism:** run independent checks concurrently via background jobs + `wait`. Target ≤ 30s full run, ≤ 8s `--quick` run.
- **Read-only:** never modify routing, DNS, WiFi, or ARP state.
- **shellcheck-clean** at default severity. `# shellcheck disable=...` only with justification.

## CLI surface

```
netdiag [TARGET] [--quick] [--quiet] [--json] [--no-gping]
        [--speed] [--no-speed] [--mtu-only] [--wifi-only]
        [--baseline] [--no-baseline] [--log PATH] [-h|--help]
```

## Output modes

- **Default:** colored human-readable stdout + ANSI-stripped log to `~/net-diag/<timestamp>.log`.
- **`--json`:** single JSON object to stdout matching the schema in `netdiag-prompt.md`. No colors, no log unless `--log` also passed.
- **`--quiet`:** only the Diagnosis section to stdout (full log still written).
- **`--quick`:** skip bufferbloat, mtr, speed test, baseline diff, WiFi scan.

## Exit codes

- `0` healthy · `1` warnings only · `2` ≥ 1 critical diagnosis · `3` script error.

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
├── docs/{ARCHITECTURE,DIAGNOSIS-RULES}.md
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

See the "Acceptance criteria" section of `netdiag-prompt.md` — all 11 items must hold before declaring the project shippable.
