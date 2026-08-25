# Reaching the features we already built

**Date:** 2026-08-25 · **Status:** proposed design, pre-plan

## Goal

Four fixes with one theme: this tool measures more than it shows, and shares
less than a user needs. A complete check exists and cannot be reached from the
app. A shareable report is named in a doc comment and was never written.
`--summary` blends every network into one meaningless distribution and
fabricates a disconnect count. `--help` documents everything in no particular
order.

Every claim below was traced to a file and a line and, where it is a runtime
behaviour, run on this machine on 2026-08-25. Nothing here is inferred.

**Out of scope:** anything on the README roadmap (Developer ID signing,
Homebrew tap, Private Relay detection, captive-DNS detection, upload
bufferbloat, confidence scoring); the accessibility of the dropdown's
instrument grid and heartbeat sparkline (real — roughly four accessibility
annotations across 11.6k lines of Swift — but a separate piece of work); and
an "act on this diagnosis" layer (open the router's admin page, copy the
advice). Both were raised and deliberately deferred.

---

## 1. The app cannot run a complete check

### Problem

`NetdiagRunner.Depth.full` has **no callers**. Verified by grep across
`gui/Sources/NetdiagGUI`: the only occurrences of `.full` as a depth are its
own two `case` arms, `NetdiagRunner.swift:89` and `:100`. Every depth passed
to `runScan` is `.quick` or `.alertTriggered`:

| Call site | Depth | Effective flags |
|---|---|---|
| `HomeView.swift:251` — "Run a check" | `.quick` | `--json --no-gping --quick` |
| `HomeView.swift:52` — "Try Again" | `.quick` | same |
| `DropdownView.swift:584` — "Check My Connection" | `.quick` | same |
| `NetdiagCoordinator.swift:309` — first join to a network | `.quick` | same |
| `NetdiagCoordinator.swift:461` — alert-triggered | `.alertTriggered` | `--json --no-gping --no-bufferbloat --no-speed` |
| `lib/launchd.sh` — the 15-minute watcher | n/a | `--quick --no-gping --no-bufferbloat --quiet` |

`--quick` skips the speed test (`lib/speedtest.sh:57`), bufferbloat
(`lib/bufferbloat.sh:20`) **and the MTU probe** (`lib/mtu.sh:13`) — the last of
those is easy to miss, because `--help` lists `--quick`'s skips as
"bufferbloat, per-hop loss, speed test, internet packet-loss probe, WiFi scan"
and does not mention MTU. So no path the app can take produces bufferbloat,
MTU or throughput.

What the user sees as a result:

- The Report card's **"Under load"**, **"Packet size (MTU)"** and **"Speed"**
  rows read "not measured" on every check the app runs
  (`RunReportView.swift:221`, `:229`, `:235`). Since the honest-status work
  landed, those rows now correctly render a grey `minus.circle` — which made
  the gap permanently visible rather than fixing it.
- Diagnosis rules **B1, B2, M1 and BL-1** can never fire from the app.
- The Trends tab can chart `bufferbloat_gw_ms`, `mtu_effective`,
  `speed_down_mbps` and `speed_up_mbps` with no source to fill them.
- The dropdown's DOWN/UP cells have a whole fallback chain ending in
  `history.latestSpeedTest` with an age label (`DropdownView.swift`,
  `speedValues`) for data the app never generates.
- Settings tells the user the background job is "what makes the History charts
  worth looking at" (`SettingsView.swift:269`) while that job runs `--quick`.

Confirmed against the live store: `./bin/netdiag --summary` over the last 24 h
and 12 runs reports `bufferbloat gw Δ (ms) … (1 samples)` and
`speedtest down (Mbps) 41.3 / 41.3 / 41.3 (1 samples)`. One sample each, and
both came from manual CLI runs.

### Fix

`Depth.full` gets exactly **two callers, both event-driven, never a timer**:

1. **An explicit "Full check" action**, secondary to the existing primary, in
   Home's header (`HomeView.swift:250`) and the dropdown (`DropdownView.swift:584`).
   It states its cost before it starts, using `Depth.full`'s own existing
   `estimate` string ("about a minute", `NetdiagRunner.swift:100`) — that
   property was written for this and has never been read.
2. **The first join to a network** — `NetdiagCoordinator.swift:309` changes
   from `.quick` to `.full`. The trigger, its `Defaults.seenNetworks`
   once-per-network guard and its `scanOnNewNetwork` setting all already
   exist; only the depth changes. This is the one automatic full check, it is
   bounded at once per network, and it lands exactly when a baseline of what
   this network can do is worth having.

**A guard, because a full check is not always safe to run.** Refuse to start
one while `monitor.latest?.status.severity` is `critical`, and offer
`.alertTriggered` depth instead. A bufferbloat probe deliberately saturates
the link; running it on a connection that is already failing makes the user's
situation worse in the middle of whatever they were doing. This is the same
reasoning `Depth.alertTriggered` already encodes by passing `--no-bufferbloat`
(`NetdiagRunner.swift:82–86`) — it is being extended to the manual path, not
invented here.

**`Depth.alertTriggered` is unchanged.** Its `--no-bufferbloat --no-speed` is
correct for the same reason as the guard above.

**The watcher stays quick**, and loses one redundant flag: `lib/launchd.sh`
passes `--no-bufferbloat` on top of `--quick`, which already skips bufferbloat.
Removing it makes the plist say what it means.

**Settings copy.** The "Run a check the first time I join a network" toggle
(`SettingsView.swift:206`) gains a caption saying that first check is a full
one and includes a speed test — the same caption pattern the Automation
section already uses one line below it, so the cost is disclosed where the
switch is.

**One empty state.** With no background full checks, a network the user has
only ever quick-checked has no bufferbloat/MTU/speed history at all. The
Trends tab's existing per-metric empty state should say so and name the
action — "no full check on this network yet" — rather than rendering an empty
chart. Same shape as `HistoryView.swift:161`'s existing sudo hint.

### Rejected alternative — a daily background full check

The first draft of this design installed a second launchd job
(`com.netdiag.watcher.full`, `StartInterval` 86400) so the speed and
bufferbloat charts would fill in on their own. Rejected on the user's
reasoning, which is better than the draft's:

> Monitoring is the continuous, cheap, always-on thing — stability, outages,
> alerts — and it should stay quick. A full check is what you run at a
> diagnosis moment: when the user says "what's going on?", or the first time
> you're on a network. We don't need to check internet speed every day.

A daily speed test spends ~50–100 MB and ~60 s of a saturated link to buy
density in a chart nobody asked for. Under this design the speed and
bufferbloat series stay sparse — one point per network plus one per manual
full check — and every point in them corresponds to a moment someone actually
wanted to know. `--speed-only` remains available for anyone who wants to add a
throughput reading cheaply; it is already recorded as a speed-only run that
does not count as a check of the network's health.

### Files

`gui/Sources/NetdiagGUI/Views/HomeView.swift`,
`Views/DropdownView.swift`,
`Services/NetdiagCoordinator.swift` (depth at `:309`, plus the severity
guard), `Views/SettingsView.swift` (caption), `Views/HistoryView.swift`
(empty state), `lib/launchd.sh` (drop the redundant flag).

---

## 2. `netdiag --share` — a report a user can paste

### Problem

The whole point of a plain-English diagnosis is that the user then tells
someone: an ISP's support chat, a landlord, a forum. Today:

- The CLI has `--redact`, which masks public IP, SSID, BSSID, IPv6, gateway
  MAC and city (`bin/netdiag:164–168`). To get pasteable text out of it you
  must also know to strip ANSI yourself — `CLAUDE.md` documents the incantation
  (`netdiag --redact | sed $'s/\\x1b\\[[0-9;]*[mK]//g'`) as a trap for
  maintainers capturing samples, which is a fair sign it is not a user-facing
  path.
- The app's **only** copy affordance is `ExpertPanel.swift:246`, which copies
  `run.rawJSON` — **unredacted**. That string contains the machine's public
  IPv4 and IPv6 addresses, SSID, BSSID, gateway MAC, ISP and city. An IPv6
  address identifies a household the way a NATed v4 address does not.
- `RunSnapshot.swift:502` already names the missing feature in a doc comment:
  *"Kept for the expert layer's JSON viewer and for 'Copy shareable report',
  which must publish exactly what the CLI produced."*

**Why `--redact` cannot simply be reused on a stored run.** Two deliberate
design decisions block it, and both are correct:

- `lib/output.sh:160–163` saves `REDACT`, forces it to `0` to build the record
  it appends to history, then restores it. The log and the history store
  **always** hold full detail; only stdout and `--json` are masked.
- `helpers/history.py:355` *drops* records that were written under `--redact`
  from the store entirely (`is_redacted`, `:281`), because a masked record
  carries `network.id = "wifi:mac=[redacted]"` and can never be grouped with a
  real network.

So there is no redacted stored copy to read, and there never will be. Redaction
of a stored run has to happen at read time.

### Fix

A new mode: `netdiag --share[=ID|-]`. One run, rendered as plain text, ANSI-free,
identifying values masked, on stdout.

**Source resolution**, in order:

- `--share -` reads one run's JSON on **stdin**. This is the path the app uses:
  it already holds the run's `rawJSON` and needs no store lookup, so it works
  for a run that finished seconds ago as well as a stored one.
- `--share=ID` resolves a stored run by id, the same way `--show=ID` does, and
  feeds it through the same renderer.
- Bare `--share` uses the most recent stored run.

**A new helper, `helpers/share.py`**, holds two things:

1. **A read-time redactor.** Collect the record's own identifying values and
   scrub each as a substring across the whole tree — the identical algorithm
   `helpers/emit_json.py:275–305` runs today, sourced from the record instead
   of from the environment.

   The field list must mirror `_REDACT_ENV` (`emit_json.py:275`) exactly,
   because that tuple's exclusions are reasoned and load-bearing:

   Record paths verified against `examples/sample-output.json` on
   2026-08-25 — note `interface.ip` and `interface.gateway_mac`, not the
   `iface.*` / `gateway.mac` an earlier draft of this table guessed at:

   | Record path | `_REDACT_ENV` name | Masked? |
   |---|---|---|
   | `public.ip` | `PUB_IP` | yes |
   | `interface.ip` | `LOCAL_IP` | yes |
   | `wifi.ssid` | `WIFI_SSID` | yes |
   | `wifi.bssid` | `WIFI_BSSID` | yes |
   | `ipv6.global_addr` | `IPV6_GLOBAL_ADDR` | yes |
   | `ipv6.gateway` | `IPV6_GATEWAY` | yes — a `fe80::` address is EUI-64-derived from the router's MAC |
   | `interface.gateway_mac` | `GW_MAC` | yes |
   | `public.city` | `PUB_CITY` | yes |
   | `public.isp`, `public.asn` | — | **no**, deliberately — they name a provider, which is what a reader needs to reason about the fault |
   | `public.country` | — | no — two characters, too short to substring-replace safely |
   | RFC1918 addresses | — | no — a `192.168.x.y` identifies nobody, and blanking it would gut the NAT and ARP sections |
   | `network.id`, `network.label` | — | no — composites of values already masked above, so the identifying parts go anyway while the readable structure survives |

   Two properties of the existing implementation come with the algorithm and
   must be preserved: the minimum-length guard (`len(v) >= 3`), so a short or
   empty field cannot scrub the document to pieces, and **longest-secret-first
   ordering**, so an SSID is masked before a shorter value that happens to sit
   inside it.

   Note for whoever implements this: `CLAUDE.md`'s own description of
   `--redact` ("public IPv6 address, ISP and city") reads as though the ISP is
   masked. It is not, by design — `examples/sample-output.txt` shows
   `TELEFONICA BRASIL S.A ([redacted], Brazil)`, provider kept, city gone.
   The code is authoritative; `CLAUDE.md`'s wording should be tightened in the
   same commit.
2. **A text renderer** for the Report card and "What we found" — the compact
   view, not the expert sections. That matches the rule `bin/netdiag:483–488`
   already enforces for `--redact`, and for the same stated reason: section
   bodies stream out before later modules have discovered everything that needs
   masking, so a partially redacted transcript is worse than none because it
   looks safe.

`share.py` renders from the JSON record, not from shell variables, so it is a
new renderer rather than a reuse of `lib/output.sh`. That is the cost of being
able to share a run that finished last week.

**In the app:** a "Copy report" button on the report card and in the dropdown
footer, piping the run's `rawJSON` into `netdiag --share -`. The existing
`ExpertPanel` copy is relabelled **"Copy raw JSON (unredacted)"** so that the
safe option is the obvious one and the unsafe one is chosen deliberately.

### Files

`helpers/share.py` (new), `bin/netdiag` (flag parsing, mode dispatch, `--help`),
`gui/Sources/NetdiagGUI/Views/RunReportView.swift`,
`Views/DropdownView.swift`, `Views/ExpertPanel.swift`,
`docs/JSON-SCHEMA.md` (document the mode alongside `--show`).

---

## 3. `--summary` becomes per-network and stops inventing numbers

### Problem

Run on this machine, 2026-08-25, `./bin/netdiag --summary`:

```
netdiag summary — last 24h (12 runs)
  incidents (any diagnosis):  9 / 12 runs
     ×   2  Your Mac is losing 100.0% of the packets it sends to your router — the box that …
  gateway loss (%)          0.0 / 0.0 / 100.0   (10 samples)
  speedtest down (Mbps)     41.3 / 41.3 / 41.3   (1 samples)
  distinct ISPs seen:        Videomar Rede Nordeste SA
  WiFi disconnect events:    173 (summed over 12 runs)
```

Five defects visible in eight lines:

1. **It ignores network identity.** Every other part of this tool is
   per-network: baselines, `--show`'s comparison block, the Networks tab,
   `history.py`'s `group_key`. `summary.py` aggregates every record in the
   window regardless of which network it came from, so a laptop that moved
   between home and a café produces one blended min/med/max describing
   neither. "distinct ISPs seen" is the only hint that this happened.
2. **`WiFi disconnect events: 173` is fabricated.**
   `wifi_disconnects.count` is a count of events in the past
   `WIFI_DISCONNECT_WINDOW_HOURS` — which is **1** (`lib/globals.sh:42`) —
   recomputed on every run. `summary.py:155` sums it across all 12 runs, so a
   run at 10:00 and a run at 10:15 both count the 09:30 event. Twelve
   overlapping one-hour windows summed over a 24-hour span is not a quantity
   of anything.
3. **`(1 samples)`.** `summary.py:78`. The GUI's Trends counts were fixed for
   exactly this in commit `3e5ca0b`; the CLI's were not.
4. **Diagnoses truncated at 80 characters** (`summary.py:120`), which in
   practice cuts each one right where the actionable half begins — the CLI
   writes "…the box that…", and the advice is in the part that was cut.
5. **No verdict anywhere.** `--summary` is the only user-facing surface in
   this tool that prints numbers without judging them. `gateway loss (%) 0.0 /
   0.0 / 100.0` reads exactly as flat as a healthy line.

### Fix

**Group by network.** Import `group_key` from `helpers/history.py` (`:252`)
rather than reimplementing it, so `--summary` and `--history` can never
disagree about what counts as one network. Emit one block per network in the
window, most-recently-seen first, under a combined header.

> Deliberately routed through `history.py`'s `group_key` and **not** through
> `lib/netid.sh`'s `netid_group`. `tests/test_history.bats:116` asserts those
> two agree and **fails on `main` today** — verified 2026-08-25: 50 of 51
> tests in that file pass and this one does not. That failure is pre-existing
> and unrelated to this work; it is filed separately as tracker item `NET.2`
> and is **not** fixed here. Importing `group_key` means `--summary` inherits
> `--history`'s grouping whatever it turns out to be, which sidesteps the
> disagreement without silently picking a winner.

**Report the busiest hour, not a sum.** Replace the `wifi_disconnects.count`
sum with the maximum across runs in the window, labelled for what it is:
"busiest hour: N disconnects". A maximum over overlapping one-hour windows is
a real quantity; a sum is not.

**Judge each metric.** Prefix each metric line with the same status glyph the
Report card already uses (`✓` / `⚠` / `×`), judged against `lib/thresholds.sh`
and reaching Python through the environment exactly as `helpers/history.py`
already does.

To keep this unambiguous: **the glyph judges the median** — the typical case,
which is what a distribution summary is for — and the line gains a trailing
note naming the worse figure when the max crosses a threshold the median does
not (`× max 100.0%`). A metric with no samples keeps its existing "no data"
and takes no glyph at all, for the same reason the Report card's unmeasured
rows render a neutral `minus.circle`: absence of a measurement is not a
verdict.

This makes `summary.py` a **fourth** consumer of the thresholds file, so two
things must be updated in the same commit or the rule stops holding:

- `CLAUDE.md`'s thresholds constraint, which today names three files
  (`lib/diagnosis.sh`, `lib/monitor.sh`, `helpers/history.py`), must name four.
- `tests/test_thresholds.bats`, which fails the build on an inline numeric
  cutoff in any of the three, must cover the fourth.

**Stop truncating.** Wrap and indent the diagnosis summaries to the terminal
width instead of cutting at 80 characters.

**`(1 sample)`.**

### Files

`helpers/summary.py`, `bin/netdiag` (pass the thresholds through, as the
`--history` invocation already does), `CLAUDE.md`,
`tests/test_thresholds.bats`, `tests/test_summary.bats`.

---

## 4. `--help` gets sections, not a split

### Problem

`--help` is roughly 110 lines in one undifferentiated wall. A user who wants
"just check my Wi-Fi" scrolls past four lines documenting `--progress`'s file
descriptor 3 protocol to reach `--wifi-only`. There is no ordering by how
likely a flag is to be wanted.

### Fix — keep it complete, give it structure

The obvious move — a short `--help` plus `--help-all` — is **rejected**.
Seven test files assert that flags appear in `--help` output, and two of them
enforce a real contract:

- `tests/test_sanity.bats:74` — "`--help` documents every flag in the
  CLAUDE.md CLI surface".
- `tests/test_capabilities.bats:146` — "every features entry maps to a real
  flag in `--help`".

Splitting the output would relocate that contract to a second flag and touch
all seven files, trading a documented invariant for a shorter first screen.

Instead, reorganise the same content into labelled sections, everyday flags
first:

- **Common** — `TARGET`, `--quick`, `--no-speed`, `--expert`, `--redact`
- **Sharing and output** — `--share`, `--json`, `--quiet`, `--log`, `--progress`
- **Just one check** — the `--*-only` family
- **Modes** — `--watch`, `--summary`, `--history`, `--show`, `--monitor`,
  the watcher install/uninstall
- **Advanced** — `--gping` / `--no-gping`, `--baseline` / `--no-baseline`,
  `--no-bufferbloat`, the `--monitor-*-interval` flags, `--version`,
  `--capabilities`, `--rules-catalog`

Same content, so every existing test passes unchanged. While here, correct
`--quick`'s own description: it lists the checks it skips and omits the MTU
probe, which it does skip (`lib/mtu.sh:13`).

### Files

`bin/netdiag` (the `--help` heredoc only).

---

## Testing

**bats — new coverage:**

- `--share` on a fixture run: no identifying value from the record survives
  into stdout; output contains no ANSI escape sequence; the Report card and
  "What we found" are present and the expert sections are not.
- `--share -` reads stdin; `--share=ID` resolves a stored run; bare `--share`
  takes the newest.
- `--summary` with records from two networks emits two blocks, and a metric
  from one does not appear in the other's distribution.
- `--summary` reports disconnects as a maximum, not a sum: three runs whose
  counts are 5, 5, 5 report 5.
- `(1 sample)` singular.
- `--share` appears in `--help` (the same convention every other mode's test
  follows).
- `tests/test_thresholds.bats` extended to `helpers/summary.py`.

**bats — existing coverage that must stay green unchanged:** the seven files
asserting flags appear in `--help`. That they need no edit is the point of
the section-only approach.

**Swift:** `swift test` runs nothing on this toolchain (see the v0.10.0
CHANGELOG entry for why). The severity guard on the full check is logic and
belongs in `--verify`, alongside the `StageResolver` assertions: a critical
severity must not permit `.full`. The buttons, captions and empty state are
pure view changes — verify with `make -C gui run` plus `--open=<tab>` and a
screenshot, the flow the Networks redesign used.

**Manual, and required before this is called done:** run a full check from the
app on this machine and confirm "Under load", "Packet size (MTU)" and "Speed"
carry real values in the Report card — the three rows this work exists to
fill.

## Sequencing

Item 4 (`--help`, one heredoc) → item 1 (the full check: two call sites, a
guard, two captions) → item 3 (`--summary`) → item 2 (`--share`, the only item
with a new helper and a new renderer, and the largest).

Items 1 and 2 both touch `DropdownView.swift` and should not be implemented in
parallel. Items 3 and 4 are independent of everything else and of each other.

Also in scope for whichever item lands first: add the `--summary` glyph
judging to `tests/test_thresholds.bats` before `summary.py` grows its first
cutoff, so the build fails on an inline number rather than after one has
already been committed.
