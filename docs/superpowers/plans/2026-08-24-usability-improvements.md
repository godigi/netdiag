# Usability Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the seven independently-shippable fixes from
`docs/superpowers/specs/2026-08-24-usability-improvements-design.md`, in the
doc's smallest-diff-first order.

**Architecture:** Seven self-contained tasks, one per spec item, no shared
state between them — any task can be skipped or reordered without breaking
another. Task 1 (CLI) is TDD via `bats`, same as the rest of `bin/netdiag`.
Tasks 2–7 (GUI) are not: this toolchain's `swift test` compiles a test
target but runs nothing (see the v0.10.0 CHANGELOG entry and
`gui/Sources/NetdiagGUI/VerifyMode.swift`'s own header — Testing.framework
ships without the `xctest` host here), and none of these six touch
`StageResolver`-level logic, so the app's `--verify` harness isn't the right
tool either. Each GUI task instead gets: a compile check
(`make -C gui build`), then a concrete manual verification procedure via
`make -C gui run` (and `--open=<tab>` where a dashboard tab is involved).

**Tech Stack:** bash 5 (`bin/netdiag`), bats-core (`tests/*.bats`), Swift 6 /
SwiftUI (`gui/Sources/NetdiagGUI`), SwiftPM (no Xcode).

---

### Task 1: CLI — reject stacking two `--*-only` flags

Spec item #7. Currently `netdiag --wifi-only --dns-only` silently keeps only
the last flag (`FOCUS="dns"` overwrites `FOCUS="wifi"`) and runs `dns-only`
with no warning, exit 0.

**Files:**
- Modify: `bin/netdiag:214` (insert helper before the arg-parsing loop),
  `bin/netdiag:244-252` (six case arms)
- Test: `tests/test_sanity.bats` (new case after the existing
  `--mtu-only`/`--quick` conflict test, currently at line 60)

- [ ] **Step 1: Write the failing test**

In `tests/test_sanity.bats`, immediately after the existing test (find it
by searching for `--mtu-only with --quick`):

```bash
@test "--mtu-only with --quick is rejected as a conflict" {
  run "$NETDIAG" --mtu-only --quick
  [ "$status" -eq 3 ]
  [[ "$output" == *"conflict"* ]]
}

@test "stacking two --*-only flags is rejected as mutually exclusive" {
  run "$NETDIAG" --wifi-only --dns-only
  [ "$status" -eq 3 ]
  [[ "$output" == *"mutually exclusive"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/test_sanity.bats -f "mutually exclusive"`
Expected: FAIL — current behavior exits 0 with a full JSON-less human report
for `dns-only`, not status 3.

- [ ] **Step 3: Add the `_set_focus` guard**

In `bin/netdiag`, find the line `_take_show=0` (it directly precedes
`while [ "$#" -gt 0 ]; do`, which starts the arg-parsing loop). Insert this
new function between them:

```bash
_take_show=0
# Each --*-only flag below overwrites FOCUS with a bare assignment —
# stacking two used to silently keep only the last one and run it with no
# warning. This guard rejects the second one instead, matching the
# --mtu-only/--quick and --speed-only/--no-speed conflicts already handled
# further down in the flag-conflict validation block.
_set_focus() {
  if [ -n "$FOCUS" ]; then
    printf 'netdiag: --%s-only and --%s-only are mutually exclusive (see --help)\n' "$FOCUS" "$1" >&2
    exit 3
  fi
  FOCUS="$1"
}
while [ "$#" -gt 0 ]; do
```

- [ ] **Step 4: Route the six `--*-only` case arms through the guard**

In `bin/netdiag`, find this block (currently lines 244-252):

```bash
    --mtu-only)       FOCUS="mtu" ;;
    --wifi-only)      FOCUS="wifi" ;;
    # --speed-only implies an explicit --speed: the whole point is "answer
    # this one question now", and leaving SPEED_EXPLICIT unset would let a
    # stray --quick silently turn the run into a no-op that still exited 0.
    --speed-only)     FOCUS="speed"; SPEED=1; SPEED_EXPLICIT=1 ;;
    --dns-only)       FOCUS="dns" ;;
    --bufferbloat-only) FOCUS="bufferbloat" ;;
    --ping-only)      FOCUS="ping" ;;
```

Replace with:

```bash
    --mtu-only)       _set_focus mtu ;;
    --wifi-only)      _set_focus wifi ;;
    # --speed-only implies an explicit --speed: the whole point is "answer
    # this one question now", and leaving SPEED_EXPLICIT unset would let a
    # stray --quick silently turn the run into a no-op that still exited 0.
    --speed-only)     _set_focus speed; SPEED=1; SPEED_EXPLICIT=1 ;;
    --dns-only)       _set_focus dns ;;
    --bufferbloat-only) _set_focus bufferbloat ;;
    --ping-only)      _set_focus ping ;;
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `bats tests/test_sanity.bats -f "mutually exclusive"`
Expected: PASS

- [ ] **Step 6: Run the full sanity suite and shellcheck**

Run: `bats tests/test_sanity.bats`
Expected: all tests PASS (confirms the six single-flag cases —
`--mtu-only` alone, etc. — still work; `FOCUS` is empty on first call so
`_set_focus` never trips for a single flag).

Run: `shellcheck bin/netdiag`
Expected: no new warnings.

- [ ] **Step 7: Commit**

```bash
git add bin/netdiag tests/test_sanity.bats
git commit -m "fix: reject stacking two --*-only flags instead of silently picking the last"
```

---

### Task 2: Dropdown — rename the mislabeled "History" button to "Activity"

Spec item #4. `DropdownView.swift`'s "History" button already opens the
correct destination (Activity, the event log — matching the "LAST 24 HOURS"
timeline it sits directly under); the label is what collides with the
app's other "history" concept (the Trends tab, internally `HistoryStore` /
`HistoryView`).

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/DropdownView.swift` (the
  `timelineSection` computed property)

- [ ] **Step 1: Rename the button**

In `gui/Sources/NetdiagGUI/Views/DropdownView.swift`, find `timelineSection`:

```swift
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("LAST 24 HOURS")
                    .font(.system(size: 9))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("History") { openActivity() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
```

Change the button line only:

```swift
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("LAST 24 HOURS")
                    .font(.system(size: 9))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Activity") { openActivity() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
```

- [ ] **Step 2: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors.

- [ ] **Step 3: Manually verify**

Run: `make -C gui run`. Click the menu-bar icon to open the dropdown. Under
"LAST 24 HOURS", confirm the button now reads "Activity". Click it; confirm
the dashboard opens on the Activity tab (same destination as before —
`MainWindow.swift`'s sidebar row labeled "Activity").

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/DropdownView.swift
git commit -m "fix(gui): rename dropdown's History button to Activity, matching its destination"
```

---

### Task 3: Home — add a "Try Again" button next to a failed-scan error

Spec item #5. `coordinator.lastRunError` currently renders as a standalone
`Label` with no attached retry action; the only retry path is the
unrelated "Run a check" button in the header above.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/HomeView.swift` (the error-`Label`
  block inside `body`)

- [ ] **Step 1: Add the retry button**

In `gui/Sources/NetdiagGUI/Views/HomeView.swift`, find (inside `body`,
directly after the `switch coordinator.reportSource` line that renders the
report, actually just before it — search for `coordinator.lastRunError`):

```swift
                if let error = coordinator.lastRunError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

Replace with:

```swift
                if let error = coordinator.lastRunError {
                    HStack(alignment: .top, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Try Again") {
                            coordinator.runScan(depth: .quick, reason: "retry after failure")
                        }
                        .controlSize(.small)
                    }
                }
```

- [ ] **Step 2: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors.

- [ ] **Step 3: Manually verify**

Run: `make -C gui run`. Force a failure to check the error path renders
correctly — easiest way: in Settings → Advanced → "netdiag command", type a
bogus path (e.g. `/tmp/not-netdiag`) into the binary-path field, then open
the dashboard's Home tab and click "Run a check" (or trigger any scan).
Confirm the orange error `Label` now has a "Try Again" button beside it,
and confirm clicking it attempts another scan (it will fail the same way
until the bogus path is cleared — that's expected; the point is the button
calls `runScan`, not that the retry succeeds). Clear the bogus path in
Settings afterward so the app finds the real CLI again.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/HomeView.swift
git commit -m "fix(gui): add a Try Again action next to a failed-scan error"
```

---

### Task 4: Home — let the Location-permission banner be dismissed for good

Spec item #1. The banner has no way to say "stop asking me here"; Settings
→ Alerts → Permissions already carries a durable, always-visible "Allow"
row, so dismissing the Home banner loses no capability.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Support/Defaults.swift` (new key +
  property)
- Modify: `gui/Sources/NetdiagGUI/Support/AppSettings.swift` (new
  observable property, mirrored in `init()`)
- Modify: `gui/Sources/NetdiagGUI/Views/HomeView.swift`
  (`locationWarningBanner`)

- [ ] **Step 1: Add the persisted key to `Defaults.swift`**

In `gui/Sources/NetdiagGUI/Support/Defaults.swift`, find the `Key` enum's
last two lines:

```swift
        static let autoCheckUpdates   = "autoCheckUpdates"
        static let lastUpdateCheck    = "lastUpdateCheck"
    }
```

Add a new key:

```swift
        static let autoCheckUpdates   = "autoCheckUpdates"
        static let lastUpdateCheck    = "lastUpdateCheck"
        static let locationBannerDismissed = "locationBannerDismissed"
    }
```

Find `hasOnboarded`'s computed property:

```swift
    static var hasOnboarded: Bool {
        get { d.bool(forKey: Key.hasOnboarded) }
        set { d.set(newValue, forKey: Key.hasOnboarded) }
    }
```

Add directly after it:

```swift
    static var hasOnboarded: Bool {
        get { d.bool(forKey: Key.hasOnboarded) }
        set { d.set(newValue, forKey: Key.hasOnboarded) }
    }

    /// Declining Location Services is a settled choice, not a per-visit
    /// question — see `HomeView.locationWarningBanner`. Settings → Alerts
    /// → Permissions keeps its own always-visible "Allow" row as the
    /// durable way back in, so this only silences the repeated ask on
    /// Home, never the feature itself.
    static var locationBannerDismissed: Bool {
        get { d.bool(forKey: Key.locationBannerDismissed) }
        set { d.set(newValue, forKey: Key.locationBannerDismissed) }
    }
```

- [ ] **Step 2: Mirror it on `AppSettings`**

In `gui/Sources/NetdiagGUI/Support/AppSettings.swift`, find:

```swift
    var hasOnboarded: Bool {
        didSet { Defaults.hasOnboarded = hasOnboarded }
    }
```

Add directly after it:

```swift
    var hasOnboarded: Bool {
        didSet { Defaults.hasOnboarded = hasOnboarded }
    }
    var locationBannerDismissed: Bool {
        didSet { Defaults.locationBannerDismissed = locationBannerDismissed }
    }
```

Find the `init()` line `hasOnboarded = Defaults.hasOnboarded` and add
directly after it:

```swift
        hasOnboarded = Defaults.hasOnboarded
        locationBannerDismissed = Defaults.locationBannerDismissed
```

- [ ] **Step 3: Gate the banner and add a dismiss button**

In `gui/Sources/NetdiagGUI/Views/HomeView.swift`, find `locationWarningBanner`:

```swift
    @ViewBuilder
    private var locationWarningBanner: some View {
        if isConnectedToWiFi && !coordinator.locationPermissions.isAuthorized {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi network name & radio diagnostics are restricted")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("macOS requires Location Services to display your network name and diagnose local radio strength. Basic fault isolation (Router vs ISP) remains active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Enable in Settings" : "Allow") {
                    if coordinator.locationPermissions.isDeniedOrRestricted {
                        coordinator.locationPermissions.openSystemSettings()
                    } else {
                        coordinator.locationPermissions.requestOrOpenSettings()
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }
```

Replace with:

```swift
    @ViewBuilder
    private var locationWarningBanner: some View {
        if isConnectedToWiFi && !coordinator.locationPermissions.isAuthorized
            && !appSettings.locationBannerDismissed {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi network name & radio diagnostics are restricted")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("macOS requires Location Services to display your network name and diagnose local radio strength. Basic fault isolation (Router vs ISP) remains active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Enable in Settings" : "Allow") {
                    if coordinator.locationPermissions.isDeniedOrRestricted {
                        coordinator.locationPermissions.openSystemSettings()
                    } else {
                        coordinator.locationPermissions.requestOrOpenSettings()
                    }
                }
                .controlSize(.small)

                // Declining is a settled choice, not a per-visit question —
                // Settings keeps its own always-on "Allow" row as the
                // durable way back in, so dismissing here loses no
                // capability, just the repetition.
                Button {
                    appSettings.locationBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors.

- [ ] **Step 5: Manually verify**

Run: `make -C gui run` on a machine (or under a login) without Location
Services granted to the app, while connected to Wi-Fi, so the banner shows
on Home. Click the "×" dismiss button; confirm the banner disappears
immediately. Quit and relaunch the app (`make -C gui run` again); confirm
the banner stays dismissed (proves persistence). Open Settings → Alerts;
confirm the "Wi-Fi & Location Access" row with its "Allow" button is still
there and unaffected.

- [ ] **Step 6: Commit**

```bash
git add gui/Sources/NetdiagGUI/Support/Defaults.swift \
        gui/Sources/NetdiagGUI/Support/AppSettings.swift \
        gui/Sources/NetdiagGUI/Views/HomeView.swift
git commit -m "fix(gui): let the Location-permission banner be dismissed for good"
```

---

### Task 5: Report card — Wi-Fi signal row shows "not measured" instead of vanishing

Spec item #3. Every other report row falls back to `"not measured"`; the
Wi-Fi signal row is currently omitted entirely when RSSI wasn't captured
(the common case without `sudo`).

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/RunReportView.swift`

- [ ] **Step 1: Change the row condition and fallback text**

In `gui/Sources/NetdiagGUI/Views/RunReportView.swift`, find:

```swift
        if let wifi = s.wifi, let rssi = wifi.rssi {
            out.append(Row(label: "Wi-Fi signal",
                           value: "\(rssi) dBm",
                           health: health(["WD-1"], ["wifi"]),
                           metricKey: "wifi_rssi_dbm",
                           glossaryKey: "wifi_signal",
                           medianFormatter: { "\(Int($0.rounded())) dBm" }))
        }
```

Replace with:

```swift
        // Unconditional on `wifi` alone, matching every other row's
        // "not measured" fallback (see `format()` below) — only the
        // presence of `rssi` inside it is optional, not the row. A wired
        // run has no `wifi` object at all and correctly shows nothing;
        // a Wi-Fi run without `sudo` now says why instead of the row just
        // not being there.
        if let wifi = s.wifi {
            out.append(Row(label: "Wi-Fi signal",
                           value: wifi.rssi.map { "\($0) dBm" } ?? "not measured — needs one sudo run",
                           health: health(["WD-1"], ["wifi"]),
                           metricKey: "wifi_rssi_dbm",
                           glossaryKey: "wifi_signal",
                           medianFormatter: { "\(Int($0.rounded())) dBm" }))
        }
```

- [ ] **Step 2: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors.

- [ ] **Step 3: Manually verify**

Run: `netdiag --json | jq '.wifi'` from a terminal on this Wi-Fi machine
without `sudo` — confirm `rssi` is `null` (the case this fix targets).
Then `make -C gui run` and, once launched, `open build/Netdiag.app --args
--open=home` (`--open=<tab>` is parsed from `CommandLine.arguments` in
`NetdiagApp.swift:89`, so it must go through `open --args`, not `make`) to
land directly on Home — or just click the menu-bar icon and open the
dashboard manually. Run a check and confirm the report card now shows a
"Wi-Fi signal" row reading "not measured — needs one sudo run" instead of
being absent. If convenient, run `sudo netdiag` once from a terminal and
re-open Home to confirm the row instead shows a real dBm value, unchanged
from before this fix.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/RunReportView.swift
git commit -m "fix(gui): show Wi-Fi signal as 'not measured' instead of hiding the row"
```

---

### Task 6: Settings — cadence sliders apply on release, not on window close

Spec item #2. Dragging a "check every…" slider updates its label instantly
but the restart only happens in `.onDisappear`, so switching away without
closing the window silently drops the change.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/SettingsView.swift` (the `general`
  computed property)

- [ ] **Step 1: Apply on each slider's release**

In `gui/Sources/NetdiagGUI/Views/SettingsView.swift`, find the three
`LabeledContent` blocks inside `Section("Monitoring")`:

```swift
                LabeledContent("Check the router every") {
                    HStack {
                        Slider(value: intervalBinding(\.fastInterval), in: 2...60, step: 1)
                        Text("\(appSettings.fastInterval)s").monospacedDigit().frame(width: 38)
                    }
                }
                LabeledContent("Check DNS and Wi-Fi every") {
                    HStack {
                        Slider(value: intervalBinding(\.mediumInterval), in: 15...600, step: 5)
                        Text("\(appSettings.mediumInterval)s").monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Check your public IP every") {
                    HStack {
                        Slider(value: intervalBinding(\.slowInterval), in: 60...1800, step: 30)
                        Text("\(appSettings.slowInterval)s").monospacedDigit().frame(width: 48)
                    }
                }
```

Replace with:

```swift
                LabeledContent("Check the router every") {
                    HStack {
                        Slider(value: intervalBinding(\.fastInterval), in: 2...60, step: 1) { editing in
                            if !editing { coordinator.applyCadenceSettings() }
                        }
                        Text("\(appSettings.fastInterval)s").monospacedDigit().frame(width: 38)
                    }
                }
                LabeledContent("Check DNS and Wi-Fi every") {
                    HStack {
                        Slider(value: intervalBinding(\.mediumInterval), in: 15...600, step: 5) { editing in
                            if !editing { coordinator.applyCadenceSettings() }
                        }
                        Text("\(appSettings.mediumInterval)s").monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Check your public IP every") {
                    HStack {
                        Slider(value: intervalBinding(\.slowInterval), in: 60...1800, step: 30) { editing in
                            if !editing { coordinator.applyCadenceSettings() }
                        }
                        Text("\(appSettings.slowInterval)s").monospacedDigit().frame(width: 48)
                    }
                }
```

- [ ] **Step 2: Update the now-outdated comment on `.onDisappear`**

Still in `general`, find:

```swift
        .formStyle(.grouped)
        // The monitor restarts once, when the window closes, rather than
        // once per slider tick: each restart respawns the process, and
        // the intervals are command-line arguments it has no way to be
        // told about mid-run.
        .onDisappear { coordinator.applyCadenceSettings() }
```

Replace with:

```swift
        .formStyle(.grouped)
        // Each slider now applies on its own release (onEditingChanged
        // above) — a restart respawns the monitor process, and the
        // intervals are command-line arguments it has no way to be told
        // about mid-run, so applying per-tick during a drag would be
        // wasteful. This onDisappear stays as a safety net for the one
        // path that doesn't fire onEditingChanged: a keyboard-driven
        // arrow-key adjustment after clicking into a slider. Occasionally
        // redundant with a release that just fired seconds earlier — a
        // harmless extra restart, not worth guarding against.
        .onDisappear { coordinator.applyCadenceSettings() }
```

- [ ] **Step 3: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors.

- [ ] **Step 4: Manually verify**

Run: `make -C gui run`. Open Settings → General. Enable "Watch my
connection continuously" if off. Drag "Check the router every" to a new
value and release the mouse (don't close the window). Watch
`log stream --predicate 'subsystem == "me.brianfreeman.netdiag"'` (the
command `make run` prints on launch) for a monitor-restart log line
appearing immediately on release, not only when the Settings window is
later closed. Then switch focus to another app (Cmd-Tab) without closing
Settings, come back, and confirm no *second* restart fires until you
either touch a slider again or actually close the window.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/SettingsView.swift
git commit -m "fix(gui): apply cadence sliders on release, not only on window close"
```

---

### Task 7: Settings — explain what each alert toggle watches for

Spec item #6. Every other Settings section pairs its toggles with a
caption; the 13-entry "Tell me about" alert list is bare titles only.
Captions must describe mechanism (trigger category, dwell/cooldown —
already-existing Swift-owned data on `AlertDefinition`), never author new
diagnosis prose — see `AlertDefinitions.swift`'s own "what Swift is
allowed to say" header.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Alerts/AlertDefinitions.swift` (new
  `caption` field + 13 literals)
- Modify: `gui/Sources/NetdiagGUI/Views/SettingsView.swift` (render the
  caption under each toggle)

- [ ] **Step 1: Add the `caption` field to the struct**

In `gui/Sources/NetdiagGUI/Alerts/AlertDefinitions.swift`, find:

```swift
    /// Fire at most once per network rather than on a clock. For the two
    /// alerts that describe a property of *this* network rather than a
    /// condition that comes and goes.
    let oncePerNetwork: Bool

    /// Neutral holding text, shown only in the gap between the alert firing
```

Insert a new field between them:

```swift
    /// Fire at most once per network rather than on a clock. For the two
    /// alerts that describe a property of *this* network rather than a
    /// condition that comes and goes.
    let oncePerNetwork: Bool

    /// One mechanism-only sentence for Settings: which category of thing
    /// this watches and how its timing works, built only from this
    /// struct's own dwell/cooldown/scanOnly/oncePerNetwork fields — never
    /// an explanation of what a firing alert means for the network. That
    /// sentence is the CLI's, verbatim, per this file's own header.
    let caption: String

    /// Neutral holding text, shown only in the gap between the alert firing
```

- [ ] **Step 2: Add a `caption:` argument to each of the 13 entries**

In the same file, `AlertDefinition.all`, add a `caption:` argument to each
entry, placed between `oncePerNetwork:` and `interimBody:` to match the new
field's declaration order (Swift's synthesized memberwise initializer
requires arguments in declaration order). Replace the whole `all` array
with:

```swift
    static let all: [AlertDefinition] = [
        AlertDefinition(
            id: "connection-lost", title: "No internet connection",
            rules: ["N1", "N1b", "P1", "P2"],
            dwell: 15, cooldown: 300, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Confirms for 15 seconds before alerting, then waits 5 minutes before repeating.",
            interimBody: "Checking what happened…"),

        AlertDefinition(
            id: "wifi-unstable", title: "Connection is unstable",
            rules: ["G1", "G2", "G3", "WD-1"],
            dwell: 25, cooldown: 1800, resolves: true, scanOnly: false,
            suppressedByICMPFilter: true, oncePerNetwork: false,
            caption: "Confirms for 25 seconds before alerting, then waits 30 minutes before repeating.",
            interimBody: "Checking whether it's your Wi-Fi or your router…"),

        AlertDefinition(
            id: "internet-degraded", title: "Internet connection degraded",
            rules: ["L1", "L2"],
            dwell: 25, cooldown: 600, resolves: true, scanOnly: false,
            suppressedByICMPFilter: true, oncePerNetwork: false,
            caption: "Confirms for 25 seconds before alerting, then waits 10 minutes before repeating.",
            interimBody: "Checking whether the loss is at your router or your internet provider…"),

        AlertDefinition(
            id: "dns-failing", title: "Websites aren't loading",
            rules: ["P1", "D1", "D3", "D4", "V6-2"],
            dwell: 30, cooldown: 1800, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Confirms for 30 seconds before alerting, then waits 30 minutes before repeating.",
            interimBody: "Checking your name lookups…"),

        AlertDefinition(
            id: "public-ip-changed", title: "Your public IP address changed",
            rules: [],   // raised from a monitor event, not a rule
            dwell: 0, cooldown: 60, resolves: false, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Fires as soon as it's seen; won't repeat within 1 minute.",
            interimBody: ""),

        AlertDefinition(
            id: "captive-portal", title: "This network needs you to sign in",
            rules: [],   // raised from public.captive_portal
            // 15 s after joining, because macOS shows its own sign-in sheet
            // first. This fires only when that sheet failed to appear —
            // which is exactly the moment a non-technical user is stranded
            // with a Wi-Fi icon that looks connected and no working web.
            dwell: 15, cooldown: 0, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: true,
            caption: "Fires once per network, 15 seconds after joining, if the sign-in page didn't open on its own.",
            interimBody: "Open your browser to sign in to this network."),

        AlertDefinition(
            id: "vpn-dropped", title: "Your VPN disconnected",
            rules: [],   // raised from a vpn.active true→false transition
            dwell: 10, cooldown: 300, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Confirms for 10 seconds before alerting, then waits 5 minutes before repeating.",
            interimBody: "Your traffic is no longer going through the VPN."),

        AlertDefinition(
            id: "clock-drift", title: "Your Mac's clock is wrong",
            rules: ["NT-1"],
            dwell: 0, cooldown: 43_200, resolves: true, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Checked only during a full check; won't repeat for 12 hours.",
            interimBody: ""),

        AlertDefinition(
            id: "ip-conflict", title: "IP address conflict",
            rules: ["DI-1", "DI-2"],
            dwell: 0, cooldown: 21_600, resolves: true, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Checked only during a full check; won't repeat for 6 hours.",
            interimBody: ""),

        AlertDefinition(
            id: "different-network", title: "This isn't the network you think",
            rules: [],   // raised from a gateway-MAC change under a known SSID
            dwell: 30, cooldown: 0, resolves: false, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: true,
            caption: "Fires once per network, 30 seconds after the router behind a familiar Wi-Fi name changes.",
            interimBody: "The Wi-Fi name is the same, but the router behind it is a different one."),


        AlertDefinition(
            id: "lease-expiring", title: "Network address expiring soon",
            rules: ["DH-1"],
            dwell: 0, cooldown: 21_600, resolves: false, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Checked only during a full check; won't repeat for 6 hours.",
            interimBody: ""),

        AlertDefinition(
            id: "slower-than-usual", title: "Slower than usual",
            rules: ["BL-1"],
            dwell: 0, cooldown: 43_200, resolves: false, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            caption: "Checked only during a full check; won't repeat for 12 hours.",
            interimBody: ""),

        AlertDefinition(
            id: "double-nat", title: "Two routers connected (Double NAT)",
            rules: ["NAT-1"],
            dwell: 0, cooldown: 86_400, resolves: true, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: true,
            caption: "Checked only during a full check; fires once per network, then won't repeat for 24 hours.",
            interimBody: "Two routers are chained together in your home, which can cause gaming and VPN issues."),
    ]
```

- [ ] **Step 3: Render the caption under each toggle**

In `gui/Sources/NetdiagGUI/Views/SettingsView.swift`, find:

```swift
            Section("Tell me about") {
                ForEach(AlertDefinition.all) { def in
                    Toggle(def.title, isOn: Binding(
                        get: { !appSettings.disabledAlerts.contains(def.id) },
                        set: { on in
                            var set = appSettings.disabledAlerts
                            if on { set.remove(def.id) } else { set.insert(def.id) }
                            appSettings.disabledAlerts = set
                        }))
                }
            }
```

Replace with:

```swift
            Section("Tell me about") {
                ForEach(AlertDefinition.all) { def in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(def.title, isOn: Binding(
                            get: { !appSettings.disabledAlerts.contains(def.id) },
                            set: { on in
                                var set = appSettings.disabledAlerts
                                if on { set.remove(def.id) } else { set.insert(def.id) }
                                appSettings.disabledAlerts = set
                            }))
                        Text(def.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
```

- [ ] **Step 4: Verify it compiles**

Run: `make -C gui build`
Expected: builds with no errors. (If it fails with a memberwise-initializer
argument-order error, double check every one of the 13 entries has
`caption:` positioned immediately after `oncePerNetwork:` and before
`interimBody:`.)

- [ ] **Step 5: Manually verify**

Run: `make -C gui run`, then open Settings → Alerts (Cmd-, from the menu
bar icon, or via the dashboard footer). Confirm all 13 toggles now show a
gray caption line underneath, and spot
check three: "No internet connection" reads "Confirms for 15 seconds
before alerting, then waits 5 minutes before repeating"; "IP address
conflict" reads "Checked only during a full check; won't repeat for 6
hours"; "Two routers connected (Double NAT)" reads "Checked only during a
full check; fires once per network, then won't repeat for 24 hours."

- [ ] **Step 6: Commit**

```bash
git add gui/Sources/NetdiagGUI/Alerts/AlertDefinitions.swift \
        gui/Sources/NetdiagGUI/Views/SettingsView.swift
git commit -m "feat(gui): explain what each alert toggle watches for and how it's timed"
```
