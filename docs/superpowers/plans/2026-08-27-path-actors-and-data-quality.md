# What else is in the path, and runs that measured two networks

**Date:** 2026-08-27
**Status:** approved
**Target version:** v0.12.0

Two chunks from `docs/design/networks-we-cannot-yet-describe.md`,
selected after v0.11.0: the Tier 2 structural idea (§2.1–2.5) and the
Tier 3 data-quality items (§3.1–3.3).

## Order: B before A

Data quality first. Chunk A adds facts to the record; Chunk B is about
whether the record describes a real network at all. Adding more fields
to a record that silently blends two networks makes the problem bigger,
not smaller.

## Chunk B — the record must describe one network (§3.1, 3.2, 3.3)

**The defect.** A full check takes ~60 s. Walk out of Wi-Fi range onto
Ethernet at second 30 and the run blends two networks, then stamps the
result with one `network.id` and files it in one network's history —
where `BL-1` later judges future runs against it. Roaming between two
mesh APs mid-run does the same to `W1`/`W2`: one meaningless averaged
RSSI describing neither radio.

**The mechanism, once, for both.** `lib/netid.sh` already computes the
identity and `lib/wifi.sh` already reads the BSSID. Capture both at the
*start* and again at the *end* of the run, compare, and when they
differ mark the record rather than reporting it as a clean measurement.
`helpers/history.py` already has the `partial` concept and already
excludes partial runs from severity voting, so the storage half exists.

New `DQ-1` (info): this run measured more than one network; its numbers
describe a transition, not a network.

**Sleep (§3.2)** is the same family in the monitor. `lib/monitor.sh:38`
says it "stays dumb about sleep" and leaves it to the GUI — but
`--monitor` is documented as a stream for *any* program, so a lid closed
for eight hours emits an eight-hour gap that a consumer reads as an
eight-hour outage. Pure arithmetic on the wall-clock delta between
samples; no new data source. Emit an explicit gap marker on the first
sample after one.

## Chunk A — one "what else is in the path" pass (§2.1–2.5)

**The unifying bug.** netdiag equates "carries my traffic" with "holds
the default route". Split tunnels, PAC proxies, DoH resolvers and
content filters each break that and each invalidate a different subset
of the report. Five separate rules would repeat the same discovery five
times.

New `lib/path.sh`, one `path_run` in the parallel batch, emitting facts:

| actor | source | no sudo |
|---|---|---|
| split-tunnel VPN | `netstat -rn` — non-default routes to `utun*` | yes |
| web proxy / PAC | `networksetup -getwebproxy` / `-getautoproxyurl` | yes |
| encrypted DNS | `scutil --dns` names DoH/DoT resolvers | yes |
| content filter | `systemextensionsctl list` | yes |

Rules: `VPN-2` (split tunnel), `PX-1` (proxy), `D5` (encrypted DNS),
`FW-1` (content filter). Each states what is in the path and which
measurements it undermines — never that it is the fault.

**Not included: iCloud Private Relay.** The detection was prototyped
today and the mechanism works, but only the "off" value has ever been
observed, so the mapping is unverified. See the design doc §2.2, which
also records the constraint that the same plist holds a location trail.

## Bash/Python split

Unchanged. All of this is bash; `emit_json.py` and `rules_catalog.py`
gain fields and entries, no logic.

## Cost

Chunk A adds four commands to the parallel batch, all ~20–100 ms, all
bounded by the batch's existing slowest member. Chunk B adds one
`netid_run` at the end of a run.
