# Usability pass — seven grounded fixes across CLI and GUI

**Date:** 2026-08-24 · **Status:** proposed design, pre-plan

## Goal

A focused polish pass, not a redesign. Both surfaces (netdiag.app's dashboard
and the `netdiag` CLI) shipped a major structural overhaul in v0.10.0; this
pass finds the next layer of friction now that structure is settled. Every
item below was traced to actual code behavior (file + line), not inferred.

**Explicitly out of scope:** anything already on the README roadmap
(Developer ID signing, Homebrew tap, Private Relay detection, captive-DNS
detection, upload bufferbloat, confidence scoring) and anything that would
add a threshold, verdict, or explanatory sentence to Swift — every fix here
is navigation, state-persistence, or UI affordance, consistent with
`CLAUDE.md`'s "the GUI holds no diagnostic logic" rule and
`AlertDefinitions.swift`'s own "what Swift is allowed to say" contract.

---

## 1. Location-permission banner never stops nagging

**Problem.** `OnboardingView.swift` (~line 61) tells the user declining
Location Services is "a perfectly reasonable answer." `HomeView.swift:148–183`
then shows an undismissable orange banner on every visit to Home while on
Wi-Fi and not authorized, asking again — with the identical ask repeated a
third time in `SettingsView.swift:167–190` (Settings → Alerts →
Permissions). The Home banner has only "Allow" / "Enable in Settings"; there
is no way to say "stop asking me here."

**Fix.** Add a persisted `locationBannerDismissed: Bool` to `AppSettings`
(same pattern as existing persisted flags like `expertExpanded`). Add a small
`xmark` dismiss control to the banner's trailing edge; tapping it sets the
flag and the banner in `HomeView.locationWarningBanner` additionally checks
`!appSettings.locationBannerDismissed`. Nothing is lost: Settings → Alerts →
Permissions keeps its own always-visible "Allow" row as the durable way to
grant the permission later, so dismissing Home's copy doesn't hide the
feature, just the repetition of it. No per-network scoping — this is a
one-time "I've seen this" flag, matching the onboarding step's own framing
that declining is a settled choice, not a per-visit question.

**Files.** `Support/AppSettings.swift` (new persisted property),
`Views/HomeView.swift` (banner condition + dismiss button).

---

## 2. Cadence sliders look live, silently apply only on window close

**Problem.** `SettingsView.swift:42–59` — dragging the three "check every…"
sliders updates the numeric label instantly. The actual restart only
happens in `.onDisappear { coordinator.applyCadenceSettings() }`
(`SettingsView.swift:128`), with a code comment explaining *why*: a restart
respawns the monitor process, and the intervals are command-line arguments
it has no way to be told mid-run — so per-tick restarts during a drag would
be wasteful. But nothing in the UI says "applies when you close this
window," so switching away without literally closing the window (clicking
into the dashboard, Cmd-Tab) silently drops the change.

**Fix.** Keep the debounce rationale (don't restart per-tick), but stop
tying the apply to *window close* — tie it to *end of drag* instead, which
is both truthful to "looks live" and still only restarts once per
completed interaction. Add `.onEditingChanged { finished in if finished {
coordinator.applyCadenceSettings() } }` to each of the three `Slider`s.
Keep the existing `.onDisappear` call as a safety net for the one path that
doesn't fire `onEditingChanged` — a keyboard-driven arrow-key adjustment
after clicking into a slider. `applyCadenceSettings()` is not currently
idempotent (`NetdiagCoordinator.swift:267`, unconditional `monitor.restart()`
when running); the redundant restart this can occasionally produce (drag,
release, immediately close the window) is a sub-second monitor blip, not
worth guarding against here.

**Files.** `Views/SettingsView.swift` only.

---

## 3. Wi-Fi signal silently vanishes without a `sudo` run — with no cross-reference

**Problem.** Two compounding gaps. First, `RunReportView.swift:176–183`:
every other report row (Router, Internet, DNS, Speed, Clock) is
unconditionally appended and falls back to `"not measured"` via the shared
`format()` helper (`RunReportView.swift:220–225`); the Wi-Fi signal row
alone is wrapped in `if let wifi = s.wifi, let rssi = wifi.rssi { … }` and
is simply absent when RSSI wasn't captured — the common case, since RSSI
needs `sudo netdiag`. Second, the *reason* is buried in `HistoryView.swift:161`
— a Trends empty-state hint reachable only by picking the "Wi-Fi signal"
metric in a chart picker, reading `"Signal strength needs sudo: run
\`sudo netdiag\` in a terminal to record it."` — an instruction to open
Terminal, in an app whose entire pitch is that it needs no CLI interaction,
and it isn't mentioned anywhere near Home or Settings.

**Fix.** Change the row condition from `if let wifi = s.wifi, let rssi =
wifi.rssi` to `if let wifi = s.wifi` (row still only appears when the run
was on Wi-Fi at all, matching existing semantics — a wired run has no `wifi`
object and correctly shows nothing), with the value falling back to
`"not measured — needs one sudo run"` when `rssi` is nil, via the same
`format()`-style helper the other rows use. This alone surfaces the gap on
every report a Wi-Fi user without sudo looks at, which is more effective
than a cross-reference from a chart empty-state most users never open.
Leave `HistoryView.swift`'s existing hint text as-is — it's still correct
and now reinforces a fact the report card already told the user.

**Files.** `Views/RunReportView.swift` only.

---

## 4. Dropdown's "History" button is correctly wired, incorrectly named

**Problem.** `DropdownView.swift:533` — a `Button("History") { openActivity()
}` sits directly under a "LAST 24 HOURS" event timeline
(`DropdownView.swift:525–548`) and opens the Activity tab
(`DropdownView.swift:690–694`, `MainWindow.swift`'s `.activity`, labeled
"Activity" in the sidebar). That destination is *correct* — Activity is
exactly the event log the timeline above the button is a preview of. The
problem is naming: the app has a second, structurally distinct concept
also called "history" internally — `HistoryStore`/`HistoryView`, sidebar
label "Trends" — and labeling this button "History" collides with that
name for a different destination a user would reasonably expect "History"
to mean (charts over time). `SettingsView.swift:392`'s About text
independently says "Monitor, History and Show need an update…", using
"History" for yet a third thing (the CLI's `--history` flag) — three
different referents for one word across the app.

**Fix.** Rename the button from `"History"` to `"Activity"`, matching the
sidebar label for the tab it actually opens. No navigation change — this is
a one-word label fix that removes the naming collision without touching
the (correct) destination.

**Files.** `Views/DropdownView.swift` line 533 only.

---

## 5. A failed scan shows the error with no adjacent way to retry

**Problem.** `HomeView.swift:45–49` renders `coordinator.lastRunError` (set
in `NetdiagCoordinator.swift:421` from `NetdiagRunner`'s `.scriptError` /
`.badJSON` cases) as a standalone orange `Label`, with no button attached to
it. The only retry path is the unrelated "Run a check" button in the header
(`HomeView.swift:229–233`), rendered well above the error and with no visual
tie to it.

**Fix.** Wrap the error `Label` in an `HStack` with a `Button("Try Again") {
coordinator.runScan(depth: .quick, reason: "retry after failure") }`
immediately beside it — same call the header's button already makes, so no
new coordinator surface is needed.

**Files.** `Views/HomeView.swift` only.

---

## 6. Alert toggles are bare titles — the one place in Settings with no caption

**Problem.** `SettingsView.swift:201–211` — every other Settings section
pairs its toggles with an explanatory caption (e.g. the Automation section,
`SettingsView.swift:196–198`: "An automatic check skips the speed test…").
The "Tell me about" alert list (13 entries in `AlertDefinition.all` — the
file's own header comment says "twelve," which is stale and out of scope
for this fix) is `Toggle(def.title, isOn: …)` with no subtitle — no
indication of what triggers each one or how naggy it is — and several
titles are unexplained jargon to a non-technical reader (e.g. "IP address
conflict", "Two routers connected (Double NAT)").

**Constraint.** `AlertDefinitions.swift`'s own header is explicit:
`title` is "a category label… navigation, not diagnosis," and "nothing in
this target composes a sentence about what is wrong with a network or what
to do about it" — that's `lib/diagnosis.sh`'s job. A caption here must
describe *mechanism* (what category of event, how it's timed) using data
`AlertDefinition` already carries — never author a new interpretive
sentence about network health.

**Fix.** Add a `caption: String` field to `AlertDefinition`, one short
mechanism-only phrase per alert authored from the struct's own existing
`dwell`/`cooldown`/`scanOnly` data — e.g. ip-conflict: "Checked only during
a full scan." · double-nat: "Checked only during a full scan, at most once
per network." · wifi-unstable: "Waits 25s to confirm, then won't repeat for
30 min." Render as a `.font(.caption).foregroundStyle(.secondary)` line
under each `Toggle`, matching the Automation section's existing pattern
exactly. This is Swift describing its own alert-timing preferences (already
Swift-owned data, per the file's "Monitoring" section precedent in
`SettingsView.swift`'s general tab), not diagnosis prose.

**Files.** `Alerts/AlertDefinitions.swift` (new field, 13 short captions),
`Views/SettingsView.swift:201–211` (render the caption).

---

## 7. CLI: stacking two `--*-only` flags fails silently

**Problem.** `bin/netdiag:244–252` — each `--*-only` flag does a bare
`FOCUS="wifi"`-style assignment with no guard. `netdiag --wifi-only
--dns-only` silently keeps only the last one and runs `dns-only` — verified
directly, no warning, exit 0. The script already validates *other* flag
conflicts this way and rejects them (`bin/netdiag:478–484`, e.g.
`--mtu-only` + `--quick`: `printf 'netdiag: --mtu-only and --quick
conflict…\n' >&2; exit 3`) — this is the one flag family that doesn't get
the same treatment as itself.

**Fix.** Add a small helper near the flag-parsing case statement:
```sh
_set_focus() {
  [ -z "$FOCUS" ] || {
    printf 'netdiag: --%s-only and --%s-only are mutually exclusive (see --help)\n' "$FOCUS" "$1" >&2
    exit 3
  }
  FOCUS="$1"
}
```
and change each `--*-only)` case arm (lines 244–252) to call `_set_focus
mtu`, `_set_focus wifi`, etc. (`--speed-only` keeps its extra `SPEED=1;
SPEED_EXPLICIT=1` alongside the call). Matches the existing exit-3,
stderr, `(see --help)` convention exactly.

**Files.** `bin/netdiag` only, lines 244–252.

**Test.** `tests/test_flags.bats` (or wherever flag-conflict cases already
live per lines 478–484's pattern) gains one case: two `--*-only` flags
together exits 3 with the mutual-exclusivity message.

---

## Verification approach

- **Item 7 (CLI)** is bats-testable directly — exit code + stderr message,
  same harness the existing `--mtu-only`/`--quick` conflict presumably
  already has a test for.
- **Items 1–6 (GUI)** have no working `swift test` runner on this toolchain
  (see `--verify`'s own rationale in the v0.10.0 CHANGELOG entry). Verify
  by: (a) the app's `--verify` harness if any of these touch
  `StageResolver`-level logic (none do — all are pure view/state changes,
  so `--verify` isn't the right tool here); (b) manual check via `make -C
  gui run` plus the existing `--open=<tab>` launch flag to land directly on
  the affected tab (Home for #1/#3/#5, Settings for #2/#6, the dropdown for
  #4) and a screenshot for visual confirmation, the same self-service flow
  the Networks tab redesign used.
- None of the seven touch `lib/thresholds.sh`, `lib/diagnosis.sh`, or
  `lib/monitor.sh` — no bats coverage needed for the thresholds-drift rule
  in `CLAUDE.md`, because nothing here introduces a numeric cutoff.

## Sequencing

No dependencies between items — all seven are independently shippable, in
any order. Smallest-diff-first is a reasonable default for the implementation
plan: #7 (CLI, ~10 lines) → #4 (one label) → #5 → #1 → #3 → #2 → #6 (13 new
caption strings, the most content to get right).
