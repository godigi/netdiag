# Tier 1 — honest link facts

**Date:** 2026-08-27
**Status:** approved (selected from `docs/design/networks-we-cannot-yet-describe.md`)
**Target version:** v0.11.0

Five items, chosen from the twenty in the design doc. Each lands as its
own commit with its own bats coverage.

## Structure

All five are bash. No Python helper gains logic; `helpers/emit_json.py`
and `helpers/rules_catalog.py` only learn new fields and new rule
entries. That keeps the bash/Python split where `docs/ARCHITECTURE.md`
put it: bash measures and judges, Python serialises and re-reads.

Two new parsers go in `lib/linkstate.sh`, which already owns "what is
this Mac actually joined to" and already takes its input as `$1` so the
tests can drive it from fixtures with no live network.

Six new cutoffs go in `lib/thresholds.sh` and nowhere else —
`tests/test_thresholds.bats` fails the build otherwise, and its
`every threshold a rule reads is defined` list must gain them too.

Six new rules. Every one needs, or the suite fails: an entry in
`helpers/rules_catalog.py`, a heading in `docs/DIAGNOSIS-RULES.md` that
its `doc` anchor resolves to, a category from the closed set, and a
blurb with no digit in it.

## Order

1. **DH-3** — a `169.254.x.x` address must not set `LINK_UP=1`.
   `linkstate_parse_ifconfig_ip` gains a link-local predicate; the
   `LINK_UP` decision in `linkstate_run` reads it. Smallest change,
   removes a confidently wrong "healthy" verdict.
2. **ETH-1 / ETH-2** — parse `ifconfig media` for negotiated rate and
   duplex, compare against the port's capability. Pure parsing, fixture
   tested. Must suppress `G2`/`G3`'s "reboot your router" advice, which
   is wrong when the cable is the fault.
3. **SP-1** — join `tx_rate` (already collected, sudo only) to the
   speed result (already collected). Arithmetic only.
4. **MET-1** — detect a metered link from the service name carrying the
   default route, and **skip the speed test by default on it**. A guard
   in `speedtest_run` alongside the existing four. Behaviour change, so
   it needs `--speed` to override and a line in the README.
5. **WI-1 + NET.4 instrumentation** — an info rule when macOS withholds
   the SSID, untruncated disconnect lines in the stored record, and
   "unavailable" rather than null for the sudo-only Wi-Fi fields.

## Open question

`MET-1` also wants suppressing in the GUI's automatic first-sighting
full check (`NetdiagCoordinator.swift:298`). The CLI guard covers it
already, since the app shells out to the CLI — so this is a
belt-and-braces question, not a gap. Deferred unless the CLI guard
proves insufficient.
