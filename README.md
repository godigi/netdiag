# netdiag

> Comprehensive network diagnostic CLI for macOS — finds the root cause of
> internet problems in one run instead of forcing you to chain eight commands.

> **Status:** v0.1.0 — repo skeleton wrapping the original 297-line starter.
> The 14 enhancements (bufferbloat, PMTU, mtr, IPv6, VPN detection, TCP reach,
> WiFi scan, disconnect history, speed test, NTP, baseline diff, custom
> target, dup-IP detection, DHCP lease) land across the v0.2.x line. See
> [`netdiag-prompt.md`](./netdiag-prompt.md) for the full spec and
> [`CHANGELOG.md`](./CHANGELOG.md) for what's shipped.

## What it does

Runs a battery of macOS network checks (interface, gateway, WiFi, DNS,
traceroute, per-hop loss), writes a timestamped log, and prints a single
root-cause **Diagnosis** section so you know whether to blame WiFi, your
router, your ISP, or DNS — without running eight tools by hand.

## Why

When the internet is flaky you usually don't have time to run `ping`,
`traceroute`, `dig`, `ipconfig`, `wdutil`, `mtr`, and `speedtest` separately
and correlate the outputs in your head. `netdiag` does that and tells you
where to look first.

## Install

Manual (works today):

```sh
git clone https://github.com/bfreeman/netdiag.git
cd netdiag
./install.sh
```

That symlinks `bin/netdiag` into `/usr/local/bin` (or `~/bin` if the system
prefix isn't writable).

Homebrew tap and one-liner installer will land alongside the v0.2.0 release.

## Usage

```
netdiag [--quick] [--no-gping] [-h|--help]
```

The full CLI surface (positional `TARGET`, `--json`, `--quiet`, `--watch`,
`--summary`, etc.) is specified in [`netdiag-prompt.md`](./netdiag-prompt.md)
and being implemented over the v0.2.x line.

## Dependencies

- **Required (macOS built-ins):** `ipconfig`, `networksetup`, `route`,
  `scutil`, `dig`, `traceroute`, `ping`, `nc`, `arp`, `curl`.
- **Optional (Homebrew):** `gping` (live monitoring on exit), `mtr`, `jq`,
  `speedtest`. Missing optional deps degrade gracefully with a hint.

## Permissions

The default run requires no `sudo`. Re-running under `sudo` unlocks rich
WiFi metrics via `wdutil info` (RSSI, noise, channel, PHY, tx rate) and
WiFi neighborhood scans.

## Roadmap

See `netdiag-prompt.md` "Future ideas" and the locked decisions in
`nimbalyst-local/plans/`. Short version:

- v0.2.x — the 14 enhancements, JSON mode, continuous monitoring.
- v0.3+ — Linux port, web UI, webhook alerts, DoH/DoT reachability checks.

## Contributing

`shellcheck` runs on every push (GitHub Actions). `bats-core` smoke tests
run on `macos-latest`. Run locally:

```sh
brew install shellcheck bats-core
shellcheck bin/netdiag install.sh
bats tests/
```

## License

[MIT](./LICENSE).
