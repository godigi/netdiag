# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-30

Initial repo skeleton — the 297-line starter script wrapped in proper repo
structure, MIT licence, and GitHub Actions CI for `shellcheck` (Ubuntu) and
`bats-core` (macOS).

### Added

- `bin/netdiag` — verbatim copy of the original `~/bin/netdiag` starter.
  Runs the existing battery of checks: interface/gateway, WiFi info, gateway
  ping, public IP, DNS, traceroute, per-hop loss, diagnosis, optional `gping`.
- `install.sh` — symlinks `bin/netdiag` into `/usr/local/bin` (or `~/bin`).
- `.github/workflows/shellcheck.yml` — runs `shellcheck` on every push/PR.
- `.github/workflows/bats.yml` — runs the bats smoke tests on `macos-latest`.
- `tests/test_sanity.bats` — `--help` smoke test (no network calls).
- `docs/ARCHITECTURE.md` and `docs/DIAGNOSIS-RULES.md` — skeleton docs.
- `LICENSE` (MIT), `CHANGELOG.md`, `.gitignore`, README skeleton.
