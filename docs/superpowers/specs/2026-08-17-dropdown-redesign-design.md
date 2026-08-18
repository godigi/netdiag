# Dropdown redesign — Adaptive Stage × Change Timeline

**Date:** 2026-08-17 · **Status:** approved design, pre-plan
**Mockups (local, not committed — `nimbalyst-local/` is gitignored):**
`nimbalyst-local/mockups/netdiag-dropdown-concepts.mockup.html` (four explored directions),
`nimbalyst-local/mockups/netdiag-dropdown-refined.mockup.html` (the approved fusion, both states).

## Goal

Replace the current `DropdownView` layout (hero + link path + glance panel + action
grid) with a design organized around the product's two promises: *constant
monitoring that alerts on any change* and *one-click deep diagnosis*. Privacy
identity (public IP, exit country, VPN) is treated as first-class monitored state,
not footer trivia. Design stance, from the approved mockup: **one swappable
"stage" at the top; everything below it never moves.**

## Layout (top to bottom)

Revised after a user-testing round on the first build (see
`docs/superpowers/plans/2026-08-17-dropdown-redesign.md`'s follow-up items):
the CTA moved up under the stage, the timeline band was cut in favor of plain
event rows, the instrument grid's first row now reads the internet-side probe
instead of duplicating the router cell, and the footer regained the two
actions the quick-action grid used to carry.

1. **Stage** — one card whose content is a function of app state (see States).
2. **Primary CTA** — the single global "Check My Connection" button, directly
   under the stage rather than at the bottom of the card. Present and
   identically positioned in every state; no second prominent button.
3. **Instrument grid** — fixed 4×2:
   - Row 1 (performance): internet ping, internet loss, download, upload
     (Mbps units shown). Ping and loss read `internet.*`, not `gateway.*` —
     the router already has its own cell in row 2, and showing the same hop
     twice was the first thing user testing flagged. A tiny right-aligned
     caption directly under this row reads `speeds from test <age>` when a
     speed test has ever run, and is absent otherwise.
   - Row 2 (link + identity): router RTT, Wi-Fi signal, VPN, location.
   - Location shows **only the country flag**. Hovering reveals a tooltip with
     the full public IP ("203.0.113.42 · click to copy"); clicking copies it.
   - Cells never disappear; an unmeasured value renders as `—`.
4. **Heartbeat strip** — a thin live sparkline of internet-side ping (the same
   series row 1's ping cell reads), captioned `internet ping · live` /
   `monitoring off` on the left and `min <n> · avg <n> · max <n> ms` (over the
   plotted window, hidden below two points) on the right. It exists to prove
   monitoring is alive without dedicating prime space to a chart.
5. **Change timeline** — "LAST 24 HOURS" header row with a trailing "History"
   button into the dashboard's Activity view, followed directly by the 2–3
   most recent events as rows (icon, phrase, time) or an empty state. The
   colored band with event ticks and a time axis from the original design is
   gone: user testing found it added a second, harder-to-read encoding of
   the same three rows underneath it without answering a question the rows
   didn't already answer.
6. **Footer** — Open Dashboard, Pause/Resume Monitoring, Settings, Quit,
   version. The first two return actions the pre-redesign quick-action grid
   carried that the first cut of this design dropped; both were among the
   first things user testing asked for back.

## Stage states

| State | Content |
|---|---|
| healthy | "✓ All good — watching" + "Nothing has changed in *N* · on *SSID*". *N* = time since the newest stored event. |
| alert | Card per the worst active alert: title, prose **verbatim from `diagnosis[].summary`**, `rule <ID> · <time>` attribution line, "See full report →" link. No buttons in the stage — the global CTA re-checks. |
| testing | Section-by-section scan progress (reuse `ScanProgressView` content) driven by `--progress`. |
| paused | "Monitoring paused" + resume affordance; instruments show last-known values, heartbeat strip flatlines. |
| skewed | Existing capabilities-handshake messaging when the bundled CLI and GUI disagree (unchanged behavior, restyled into the stage). |

Only the stage and any out-of-threshold instrument value (colored by the same
severity the CLI reports) change between states.

## Data sources — everything user-facing comes from the CLI

| UI element | Source |
|---|---|
| Instruments row 1 | monitor `internet.rtt_avg_ms`, `internet.loss_pct`; speeds from the most recent stored run via history (age shown as a caption under the row, not in the heartbeat) |
| Instruments row 2 | monitor `gateway.rtt_avg_ms`/`gateway.loss_pct` (router cell), `link.*` (interface, SSID), `vpn.*`, `wifi.rssi` (falling back to a live CoreWLAN read when Location Services is authorized and the slow tier hasn't measured yet); slow tier `public.ip`, `public.country_iso` → flag |
| Heartbeat strip + caption | monitor `internet.rtt_avg_ms` (same field row 1's ping cell reads); min/avg/max computed client-side over the plotted window — arithmetic, not a threshold |
| Alert title/prose | `status.rules` + `diagnosis[].summary` verbatim; plain-language layer via `--rules-catalog` |
| Timeline events | `changes` array on monitor samples (below) plus scan-produced alerts; `rule-fired`/`rule-cleared` summaries are the catalog's rule title, not the bare rule ID |
| Severity colors | `status.severity` / `status.rules`, thresholds already applied by `lib/monitor.sh` / `lib/diagnosis.sh`; the GUI maps severity → color only |
| Paused state | `status.paused` (SIGUSR1/SIGUSR2 contract unchanged) |

## New CLI surface required

`lib/monitor.sh` gains change detection: when a tracked field differs from the
previous sample, the emitted line includes
`changes: [{id, field, from, to, summary}]`, where `summary` is the
user-facing phrase (e.g. "VPN exit moved: Germany → Brazil"). Tracked fields:
public IP, country, ISP/ASN, VPN state and name, SSID/BSSID, interface, and
rule-set transitions (a rule newly firing or clearing). Comparing *this sample
to the last* is state the monitor already holds; phrasing the change in bash
keeps the "no user-facing verdict strings in Swift" rule intact. Schema:
`monitor` bumps 1 → 2; the GUI gates the event feed on `--capabilities`
`schemas.monitor >= 2`, so an older CLI degrades the GUI to a tickless
timeline rather than breaking it. (Not a `features` entry: that list is
CI-checked against literal `--help` flags, and this is a schema property,
which `schemas` already expresses.) Change **detection** is field
inequality, not thresholds — no new numeric cutoffs, so `lib/thresholds.sh`
is untouched.

## Event persistence

The monitor writes nothing to disk (existing contract). The GUI appends
received `changes` and scan alerts to its existing local alert store, prunes
at 24 h for the band (full history stays in the dashboard), and derives both
the band ticks and "nothing has changed in *N*" from that store. Persistence
and rendering of CLI-authored events is not diagnostic logic.

## Privacy behavior

- Default dropdown face shows no public IP — flag only; hover to reveal, click
  to copy. Screen-sharing a menu open is the common leak path this closes.
- Identity changes surface as events (they are the story; the static value is
  not), with country transitions phrased by the CLI.

## Removed from the current dropdown

The 3-hop link path bar, the quick-action grid, and the contextual remedy row
(remedies live in the alert stage's full report). The glance panel's facts are
absorbed by the instrument grid. Live-latency toggle is replaced by the
always-on heartbeat strip.

## Edge cases

- **Cold launch:** hydrate instruments and timeline from history + alert store
  (existing hydration path); stage shows healthy/alert per last verdict with
  its age.
- **No speed test ever run:** speed cells show `—`; the "speeds from test …"
  caption is simply absent rather than replaced with placeholder text —
  shown only once `speedValues.age` resolves to a real value.
- **Flag rendering:** `country_iso` → regional-indicator scalars; unknown or
  redacted → 🌐 placeholder, tooltip "location unknown".
- **Malformed monitor lines:** skipped, as consumers already must.

## Testing

- bats: `changes` emission (VPN flip, SSID change, rule transition, no-change
  sample emits no array), schema version, capabilities entry;
  `tests/test_thresholds.bats` must stay green (no new inline cutoffs).
- GUI: unit-test the event store pruning and "time since last change"
  derivation; state-machine coverage that stage selection follows
  monitor/scan/pause/skew inputs.

## Out of scope

Dashboard/Activity redesign, the eye-mask redaction toggle from the
identity-first concept (revisit later), notification behavior changes, and any
change to `--watch`.
