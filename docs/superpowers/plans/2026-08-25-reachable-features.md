# Reachable Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make four already-built capabilities reachable — a complete network check from the app, a pasteable redacted report, a per-network `--summary` that stops inventing numbers, and a `--help` you can navigate.

**Architecture:** Four independent workstreams against the spec at `docs/superpowers/specs/2026-08-25-reachable-features-design.md`. Item 1 is Swift-only plus one line of bash. Item 2 adds one Python helper and one CLI mode, then a button. Items 3 and 4 are CLI-only. The project's standing rules hold throughout: thresholds live only in `lib/thresholds.sh`, and the GUI renders CLI decisions rather than making its own (`CLAUDE.md`).

**Tech Stack:** bash 5 / zsh, Python 3 (stdlib only), SwiftUI + SwiftPM (no Xcode), bats-core, shellcheck.

---

## Ground rules for every task

**Verification commands** (run from the repo root, `/Users/bfreeman/Documents/AI-Workspace/netdiag`):

```bash
bats tests/                                      # full suite
bats tests/test_summary.bats                     # one file
shellcheck -x bin/netdiag lib/*.sh               # CI's exact scope
make -C gui build                                # Swift build
swift run --package-path gui NetdiagGUI --verify  # the GUI's test harness
```

**One pre-existing failure is expected and is not yours to fix.**
`tests/test_history.bats:116` — *"netid_run's NETWORK_GROUP equals the group key history.py assigns"* — fails on `main` today (verified 2026-08-25: 50 of 51 in that file pass). It is filed as tracker item `NET.2`. When you run the full suite, **1 failure is the clean baseline**. If you see 2, you caused one.

Capture the baseline before you start:

```bash
bats tests/ 2>&1 | grep -c '^not ok'    # expect: 1
```

**Python here is 3.9.6** (Command Line Tools), verified 2026-08-25. That is
older than the syntax in this plan looks: `float | None` in a signature and
`dict[str, list[dict]]` on a variable are only legal because every helper
starts with `from __future__ import annotations`, which makes annotations
strings rather than evaluated expressions. `helpers/summary.py` already has
that import; `helpers/share.py` must keep the one this plan gives it. If you
find yourself needing a union **at runtime** — in an `isinstance` call, say —
write `(float, int)`, not `float | int`, or it raises on 3.9.

**`swift test` does not work on this machine** and never will — the Command Line Tools ship Swift Testing's framework but not the `xctest` host, so a test target compiles and runs nothing. Swift logic is verified through the app's own `--verify` harness (`gui/Sources/NetdiagGUI/VerifyMode.swift`); Swift views are verified by running the app. Do not add a test target.

**Commit after every task.** Messages use `feat:` / `fix:` / `docs:` / `test:` and state the user-visible outcome.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `helpers/share.py` | Read-time redaction of one run record + plain-text rendering of it. Two responsibilities, but they are the two halves of one pipeline and share no state with anything else. |
| `gui/Sources/NetdiagGUI/Support/FullCheckPolicy.swift` | The single pure predicate "is it safe to run a full check right now?". Pure so `--verify` can assert it, mirroring `Support/StageResolver.swift`. |
| `tests/test_summary.bats` | Coverage for `--summary`. No such file exists today. |
| `tests/test_share.bats` | Coverage for `--share`. |

**Modified:**

| Path | Change |
|---|---|
| `bin/netdiag` | `--help` reorganised; `--share` flag parsing and mode dispatch; thresholds exported to `summary.py` |
| `helpers/summary.py` | Per-network grouping, max-not-sum disconnects, threshold judging, wrapping, pluralisation |
| `lib/launchd.sh` | Drop the redundant `--no-bufferbloat` |
| `lib/thresholds.sh` | No new values — read only |
| `gui/.../Services/NetdiagCoordinator.swift` | First-join depth; full-check entry point + guard |
| `gui/.../Services/NetdiagRunner.swift` | `execute` gains optional stdin; a `share(rawJSON:)` call |
| `gui/.../Views/HomeView.swift` | "Full check" secondary action |
| `gui/.../Views/DropdownView.swift` | "Full check" secondary action; "Copy report" |
| `gui/.../Views/RunReportView.swift` | "Copy report" |
| `gui/.../Views/ExpertPanel.swift` | Relabel the raw-JSON copy |
| `gui/.../Views/SettingsView.swift` | First-join caption |
| `gui/.../Views/HistoryView.swift` | Empty-state hints name the button, not the terminal |
| `gui/.../VerifyMode.swift` | Assert `FullCheckPolicy` |
| `CLAUDE.md` | Thresholds rule names four consumers; `--redact` wording corrected |
| `tests/test_thresholds.bats` | Guard extended to `summary.py` |
| `docs/JSON-SCHEMA.md`, `README.md`, `CHANGELOG.md` | Document `--share` |

---

# Item 4 — `--help` gets sections

Done first because it is self-contained and touches one heredoc.

## Task 1: Reorganise `--help` without splitting it

**Why not `--help-all`:** seven test files assert flags appear in `--help`, two of which enforce real contracts — `tests/test_sanity.bats:74` ("documents every flag in the CLAUDE.md CLI surface") and `tests/test_capabilities.bats:146` ("every features entry maps to a real flag in --help"). A split relocates that contract. Sections keep it.

**Files:**
- Modify: `bin/netdiag:348-459` (the `cat <<'HELP' … HELP` heredoc)
- Test: `tests/test_sanity.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_sanity.bats`:

```bash
@test "--help is organised into labelled sections" {
  # A 110-line wall of flags in no particular order made a user scroll
  # past --progress's file-descriptor protocol to reach --wifi-only.
  # The sections are the navigation; this asserts they exist and stay.
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  for section in "Common:" "Sharing and output:" "Just one check:" \
                 "Modes" "Advanced:"; do
    [[ "$output" == *"$section"* ]] || {
      echo "missing section from --help: $section"
      return 1
    }
  done
}

@test "--quick's own description admits it skips the MTU probe" {
  # lib/mtu.sh:13 returns early under --quick, but --help listed the
  # skips as "bufferbloat, per-hop loss, speed test, internet
  # packet-loss probe, WiFi scan" and never said so. A user reading
  # only --help would expect an MTU number and get "not measured".
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  local quick_block
  quick_block="$(printf '%s\n' "$output" | grep -A 3 -- '--quick  ')"
  [[ "$quick_block" == *"MTU"* ]] || {
    echo "--quick's help text does not mention MTU:"
    echo "$quick_block"
    return 1
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats tests/test_sanity.bats
```

Expected: both new tests FAIL — the first reporting `missing section from --help: Common:`, the second reporting that `--quick`'s block has no `MTU`.

- [ ] **Step 3: Rewrite the heredoc**

Replace the body of `bin/netdiag`'s help heredoc (between `cat <<'HELP'` at line 348 and `HELP` at line 459) with the same content regrouped. Keep **every** flag string byte-identical to what is there now — the seven test files match on exact flag text, and this task must not change a single one.

The intro paragraph and `Usage:` block stay as they are. After the `Positional:` block, the flag list is regrouped under these five headings, in this order:

```
Common:
  --quick           skip slow checks (bufferbloat, per-hop loss, speed
                    test, internet packet-loss probe, MTU probe, WiFi
                    scan). Finishes in ~8 s on a healthy network.
  --no-speed        skip the speedtest — use on metered or slow links, and
                    to bring a full run back under ~30 s
  --expert          show every detailed measurement section (RSSI, full
                    DNS / TCP / traceroute / DHCP / per-hop loss). Default
                    output is a compact Report card + diagnoses only.
  --redact          mask identifying values (public IP, SSID, BSSID, IPv6
                    address, gateway MAC, city) on stdout and in --json so
                    the report is safe to paste into a forum or ticket.
                    The ISP name is deliberately kept — it is what makes
                    the report useful to read. The log file on disk keeps
                    full detail. Implies compact output (--expert is
                    ignored).

Sharing and output:
  --share[=ID|-]    print one run as plain text, no colours, identifying
                    values masked — the paste-ready form of a report.
                    Bare: the most recent stored run. =ID: that stored run
                    (ids come from --history). =-: read one run's JSON on
                    stdin.
  --json            emit one JSON object on stdout; no human-readable output
                    unless --log PATH is also passed
  --quiet           print only the diagnoses; suppress the Report card too
  --log PATH        write the human-readable log to PATH (default
                    ~/net-diag/<timestamp>.log)
  --progress        stream one JSON progress event per line on fd 3 (which
                    is pointed at stderr) as the run moves through its
                    phases: the plan, each phase starting and finishing,
                    and the speed test's own stages. stdout is untouched,
                    so --json --progress still emits exactly one object.
                    See docs/JSON-SCHEMA.md for the event reference.

Just one check:
  --mtu-only        run only the path-MTU probe (plus the interface and
                    public-reach checks it depends on)
  --wifi-only       run only the WiFi checks: link quality, neighbourhood
                    scan, and disconnect history
  --speed-only      run only the speed test (plus the interface, gateway
                    and public-reach checks it depends on). Recorded in
                    history as a speed-only run, so it adds a throughput
                    reading without counting as a check of your network's
                    health.
  --dns-only        run only the DNS checks and resolvers probe
  --bufferbloat-only run only the bufferbloat load test
  --ping-only       run only gateway and internet latency / packet loss probes
```

Then the existing `Modes (exit after running, don't run the normal check battery):` block, verbatim and unchanged. Then:

```
Advanced:
  --speed           run the speedtest even under --quick (it is already on
                    by default in a normal run; ~30 s and ~50 MB)
  --no-bufferbloat  skip the 100 MB / 10 s bufferbloat probe (saves data on
                    metered links)
  --gping           after the report, launch a live ping monitor on the
                    discovered hops (gping must be installed). Without
                    this flag you'll be prompted; default is no.
  --no-gping        skip the gping prompt entirely (used by scripts /
                    watchers; equivalent to answering "no" upfront)
  --baseline        compare this run against medians of the last 10 runs
                    in ~/net-diag/baseline.jsonl (default on)
  --no-baseline     skip the baseline comparison and don't append to history
```

Move `--version`, `--capabilities`, `--rules-catalog` and `--signal-scale` (currently at the tail of the Modes block) so they sit at the end of `Advanced:`, text unchanged.

Update the `Usage:` line to include `--share`:

```
Usage: netdiag [TARGET] [--quick] [--gping] [--no-bufferbloat] [--speed]
               [--json] [--quiet] [--expert] [--progress] [--log PATH]
               [--share[=ID]]
               [--mtu-only | --wifi-only | --speed-only | --dns-only |
                --bufferbloat-only | --ping-only]
```

> `--share` is documented here but not implemented until Task 12. That is deliberate: `tests/test_sanity.bats:74` reads the flag list from `CLAUDE.md`, and `CLAUDE.md` does not mention `--share` yet either, so nothing asserts on it in between. Task 13 adds both together.
>
> If you would rather not document an unimplemented flag, omit the `--share` lines from this task and add them in Task 13. Everything else in Task 1 stands either way.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats tests/test_sanity.bats && bats tests/test_capabilities.bats && \
  bats tests/test_progress.bats && bats tests/test_monitor.bats && \
  bats tests/test_history.bats && bats tests/test_rules_catalog.bats
```

Expected: all PASS except the one known `test_history.bats` failure. The six pre-existing "documented in --help" tests passing unchanged is the point of this task — if any of them fails you changed a flag string.

- [ ] **Step 5: shellcheck**

```bash
shellcheck -x bin/netdiag lib/*.sh
```

Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add bin/netdiag tests/test_sanity.bats
git commit -m "docs: group --help into sections and admit --quick skips MTU

The flag list was 110 lines in no particular order, so reaching
--wifi-only meant scrolling past --progress's file-descriptor
protocol. Same content, five sections, everyday flags first.

Kept whole rather than split into --help-all: seven test files
assert flags appear in --help, two of them enforcing that it
documents every flag in the CLAUDE.md surface and that every
advertised capability maps to a real one. A split would relocate
that contract rather than honour it.

--quick returns early from lib/mtu.sh:13 and never said so."
```

---

# Item 1 — a complete check the app can run

## Task 2: A pure, verifiable safety predicate

**Why a separate type:** the guard must be assertable by `--verify`, and `--verify` cannot construct a live `NetdiagCoordinator` (it spawns a monitor and reads history). Pure logic in `Support/` asserted by the harness is the pattern `StageResolver` already established.

**Files:**
- Create: `gui/Sources/NetdiagGUI/Support/FullCheckPolicy.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing assertions**

In `gui/Sources/NetdiagGUI/VerifyMode.swift`, add this function to `VerifyHarness` (place it immediately after `runStageTests()`'s closing brace):

```swift
    // MARK: - Full-check policy
    //
    // A full check runs a bufferbloat probe that deliberately saturates
    // the link for ~10 s. Doing that to a connection already reporting
    // critical makes the user's situation worse in the middle of the
    // problem they opened the app about. Same reasoning
    // NetdiagRunner.Depth.alertTriggered already encodes by passing
    // --no-bufferbloat; this extends it to the manual path.

    private static func runFullCheckPolicyTests() {
        print("\nFullCheckPolicy")
        equal(FullCheckPolicy.isSafe(severity: "ok"), true, "ok permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "info"), true, "info permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "warn"), true, "warn permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "critical"), false, "critical blocks a full check")
        // An unrecognised severity must not silently read as safe: the
        // CLI is the authority on this vocabulary and a value we do not
        // know is a value we cannot clear.
        equal(FullCheckPolicy.isSafe(severity: ""), false, "unknown severity blocks a full check")
        equal(FullCheckPolicy.isSafe(severity: "catastrophic"), false, "unrecognised severity blocks a full check")
    }
```

And add the call inside `run()`, between `runStageTests()` and `runSnapshots()`:

```swift
        runStageTests()
        runFullCheckPolicyTests()
        runSnapshots()
```

- [ ] **Step 2: Run to verify it fails**

```bash
make -C gui build
```

Expected: FAIL to compile — `cannot find 'FullCheckPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `gui/Sources/NetdiagGUI/Support/FullCheckPolicy.swift`:

```swift
import Foundation

/// Whether a full check is safe to start right now.
///
/// A full check is the only depth that runs the bufferbloat probe, and
/// that probe deliberately saturates the link for ~10 s to measure
/// latency under load. On a connection already reporting `critical` that
/// is actively harmful: the user opened the app *because* something is
/// wrong, and the app's response would be to make the thing that is wrong
/// worse for ten seconds. `NetdiagRunner.Depth.alertTriggered` already
/// encodes this by passing `--no-bufferbloat`; this predicate extends the
/// same reasoning to the button a user presses themselves.
///
/// Pure, and deliberately not a computed property on the coordinator:
/// `VerifyMode` is the only runnable test harness on this toolchain and it
/// cannot construct a coordinator (that spawns a monitor and reads
/// history). Same shape and same reason as `StageResolver`.
///
/// This is not a threshold. It reads the CLI's own severity vocabulary and
/// compares strings; it never decides what makes a network critical. That
/// stays in `lib/thresholds.sh`, per CLAUDE.md.
enum FullCheckPolicy {

    /// The CLI severities that permit a full check. Allow-list rather than
    /// a `!= "critical"` deny-list: an unrecognised severity — a value from
    /// a newer CLI, or an empty string from a monitor that has not produced
    /// a sample yet — must not read as "safe". We cannot clear a verdict we
    /// do not understand.
    private static let safe: Set<String> = ["ok", "info", "warn"]

    static func isSafe(severity: String) -> Bool {
        safe.contains(severity)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
make -C gui build && swift run --package-path gui NetdiagGUI --verify
```

Expected: build clean, and the harness prints a `FullCheckPolicy` section with six `✔` lines and exits 0.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Support/FullCheckPolicy.swift gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): add the full-check safety predicate

A full check is the only depth that runs bufferbloat, which
saturates the link for ~10 s on purpose. Running it against a
connection already reporting critical makes the user's problem
worse while they are watching it. Depth.alertTriggered already
refuses for this reason; the manual path needs the same rule.

Allow-list, not a != critical deny-list: an empty or unrecognised
severity must not read as safe. Pure and in Support/ so --verify
can assert it, the same shape as StageResolver."
```

## Task 3: Give `Depth.full` its first caller

`NetdiagRunner.Depth.full` has no call sites today — verified by grep, its only appearances are its own `case` arms at `NetdiagRunner.swift:89` and `:100`.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`

- [ ] **Step 1: Add the entry point**

In `NetdiagCoordinator.swift`, immediately after the existing `runScan(depth:reason:target:)` (line 358), add:

```swift
    /// Whether the "Full check" action should be offered as runnable right
    /// now. Read by the views to disable the control and say why.
    var fullCheckIsSafe: Bool {
        FullCheckPolicy.isSafe(severity: monitor.latest?.status.severity ?? "")
    }

    /// The full battery: bufferbloat, the MTU probe, per-hop loss and a
    /// speed test — none of which any other depth produces, and all of
    /// which the Report card, the Trends charts and the dropdown's
    /// throughput cells are built to display.
    ///
    /// Refuses while the CLI's verdict is critical, and falls back to the
    /// alert-triggered depth instead of doing nothing: someone who pressed
    /// this button wants a check, and the lighter one is still worth
    /// running. See `FullCheckPolicy` for why bufferbloat is the specific
    /// hazard.
    func runFullCheck(reason: String = "you asked for a full check") {
        guard fullCheckIsSafe else {
            runScan(depth: .alertTriggered, reason: reason)
            return
        }
        runScan(depth: .full, reason: reason)
    }
```

- [ ] **Step 2: Change the first-join depth**

At `NetdiagCoordinator.swift:309`, change:

```swift
        runScan(depth: .quick, reason: "new network")
```

to:

```swift
        // The one automatic full check, and the reason there is no timed
        // one: joining a network for the first time is exactly when a
        // baseline of what it can do — throughput, bufferbloat, path MTU —
        // is worth having, and the `seenNetworks` guard above bounds it to
        // once per network for the life of the install. Monitoring covers
        // the continuous question; this covers the one-off one.
        runFullCheck(reason: "new network")
```

- [ ] **Step 3: Build**

```bash
make -C gui build
```

Expected: clean, no warnings.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
git commit -m "feat(gui): give Depth.full its first caller

Depth.full had no call sites — grep across the whole target found
only its own two case arms. Every scan the app could run was
--quick or the alert profile, so bufferbloat, the MTU probe and
the speed test were unreachable: three Report rows read 'not
measured' forever, rules B1/B2/M1/BL-1 could never fire, and four
Trends charts had no source.

First join to a network now runs a full check instead of a quick
one. It is bounded to once per network by the seenNetworks guard
that was already there, and it is the moment a baseline of what
this network can do is worth recording.

Refuses while severity is critical and runs the alert-triggered
depth instead, so pressing the button always does something."
```

## Task 4: The "Full check" action in Home

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/HomeView.swift:249-254`

- [ ] **Step 1: Replace the header's single button**

In `HomeView.swift`, the `header` property's `else` branch currently reads:

```swift
            } else {
                Button("Run a check") {
                    coordinator.runScan(depth: .quick, reason: "you asked")
                }
                .keyboardShortcut("r")
            }
```

Replace it with:

```swift
            } else {
                HStack(spacing: 8) {
                    // Secondary, and second: the quick check answers "is it
                    // broken right now" while the problem is still
                    // happening, and that stays the default. This one is
                    // the deliberate, slower question — the only depth that
                    // measures throughput, latency under load and path MTU.
                    Button(fullCheckLabel) {
                        coordinator.runFullCheck()
                    }
                    .help(fullCheckHelp)

                    Button("Run a check") {
                        coordinator.runScan(depth: .quick, reason: "you asked")
                    }
                    .keyboardShortcut("r")
                    .buttonStyle(.borderedProminent)
                }
            }
```

- [ ] **Step 2: Add the two label properties**

Add immediately after the `header` property's closing brace, before `elapsedLabel(at:)`:

```swift
    /// The full check's own cost, stated on the control rather than
    /// discovered by pressing it. `Depth.full.estimate` is the CLI's
    /// budget — the same string that has existed unread since the depth
    /// was written.
    private var fullCheckLabel: String {
        "Full check · \(NetdiagRunner.Depth.full.estimate)"
    }

    /// Says what the extra minute buys, and — when the connection is
    /// already failing — why the button will quietly do something lighter.
    /// The wording describes what netdiag measures, never what it concludes
    /// about this network; the verdicts stay in the CLI's own prose below.
    private var fullCheckHelp: String {
        coordinator.fullCheckIsSafe
            ? "Adds speed, latency under load, path MTU and per-hop loss to the report."
            : "Your connection is failing right now, so this will skip the load test — measuring it would saturate the link you are trying to use."
    }
```

- [ ] **Step 3: Build and run**

```bash
make -C gui build && make -C gui run
```

Then, with the app running, open the dashboard on Home and confirm two buttons sit in the header: a bordered-prominent "Run a check" and a plain "Full check · about a minute".

- [ ] **Step 4: Verify the full check actually fills the blank rows**

This is the manual check the whole item exists for. Press **Full check**, wait for it to finish (~1 minute), and confirm the Report card's **Under load**, **Packet size (MTU)** and **Speed** rows now carry real values rather than "not measured" with a grey `minus.circle`.

If they still read "not measured", stop and diagnose before continuing — the item is not done.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/HomeView.swift
git commit -m "feat(gui): add a Full check action to Home

The only way to fill the Under load, Packet size (MTU) and Speed
rows was to open a terminal. Now it is a button, stating its own
cost from Depth.full's estimate string — written when the depth
was added and never read until now.

Secondary to Run a check, which stays primary: a quick check
answers 'is it broken right now' while the problem is still
happening, and that is the commoner question."
```

## Task 5: The "Full check" action in the dropdown

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/DropdownView.swift:578-594`

- [ ] **Step 1: Add a secondary action under the CTA**

`DropdownView.swift`'s `checkButton` keeps its existing comment and body exactly as they are. Wrap it and a new secondary button:

```swift
    private var checkButton: some View {
        VStack(spacing: 4) {
            Button {
                // This is the status button, not a throughput benchmark. The
                // quick profile checks the gateway, DNS, TCP and public HTTPS
                // path without traceroute, bufferbloat or a speed test, so the
                // answer arrives while the problem is still happening.
                coordinator.runScan(depth: .quick, reason: "you asked")
            } label: {
                HStack {
                    Image(systemName: "stethoscope")
                    Text("Check My Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.isScanning)

            // The throughput benchmark the button above deliberately is
            // not. Kept visually quieter and stating its cost, because a
            // menu-bar click that saturates the link for a minute should
            // never be the one you hit by accident.
            Button("Full check · \(NetdiagRunner.Depth.full.estimate)") {
                coordinator.runFullCheck()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(coordinator.isScanning)
        }
    }
```

- [ ] **Step 2: Build and verify**

```bash
make -C gui build && make -C gui run
```

Click the menu-bar icon. Confirm "Check My Connection" is unchanged and a small secondary "Full check · about a minute" sits directly under it.

- [ ] **Step 3: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/DropdownView.swift
git commit -m "feat(gui): offer a full check from the dropdown too

Quieter than the primary CTA and labelled with its cost — a
menu-bar click that saturates the link for a minute should not be
the one you hit by accident."
```

## Task 6: Say the first-join check is a full one

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/SettingsView.swift:204-210`

- [ ] **Step 1: Split the Automation captions**

The Automation section currently pairs both toggles with one caption. Replace the section body with:

```swift
            Section("Automation") {
                Toggle("Run a check automatically when something breaks", isOn: $appSettings.scanOnAlert)
                Text("An automatic check skips the speed test, so it won't slow down a connection that is already struggling.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Run a check the first time I join a network", isOn: $appSettings.scanOnNewNetwork)
                // The cost is disclosed at the switch that causes it. This
                // is the only automatic full check netdiag runs — there is
                // no timed one — so it is the only place a speed test
                // happens without someone pressing a button.
                Text("This first check is a full one: it includes a speed test and takes about a minute. It runs once per network, ever.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

- [ ] **Step 2: Build and verify**

```bash
make -C gui build && make -C gui run
```

Open Settings → Alerts → Automation and confirm each toggle now has its own caption directly beneath it.

- [ ] **Step 3: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/SettingsView.swift
git commit -m "docs(gui): disclose that the first-join check is a full one

It now runs a speed test, and the switch that causes that is where
it should be said. Splits the Automation section's shared caption
so each toggle describes its own behaviour."
```

## Task 7: Trends empty states name the button, not the terminal

`HistoryView.hint(for:)` currently tells a user that speed tests "only run in a full check, not in --quick — and the launchd watcher uses --quick", and that RSSI needs `sudo netdiag` "in a terminal". The first sentence stops being true the moment Task 3 lands; the second is an instruction to leave the app.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/HistoryView.swift:155-169`

- [ ] **Step 1: Rewrite the hints**

```swift
    /// Why a metric is empty is usually a fact about how netdiag is being
    /// run, and saying so turns a dead chart into an instruction. Since a
    /// full check became reachable from Home and the menu bar, the
    /// instruction is a button rather than a terminal — except for RSSI,
    /// which still genuinely needs a privileged run.
    private func hint(for key: String) -> String {
        switch key {
        case "speed_down_mbps", "speed_up_mbps":
            return "Speed is only measured by a full check. Press \"Full check\" on Home, or join a new network — netdiag runs one automatically the first time."
        case "wifi_rssi_dbm", "wifi_snr_db":
            return "Signal strength needs sudo: run `sudo netdiag` in a terminal to record it."
        case "bufferbloat_gw_ms", "bufferbloat_inet_ms":
            return "Latency under load is only measured by a full check, and is skipped entirely while a connection is already failing."
        case "mtu_effective":
            return "Path MTU is only measured by a full check — the quick check and the background watcher both skip it."
        case "inet_rtt_ms", "inet_loss_pct":
            return "The internet loss probe is skipped by the quick check that the background watcher runs."
        default:
            return "It may be skipped by the check mode you normally run."
        }
    }
```

- [ ] **Step 2: Build and verify**

```bash
make -C gui build && make -C gui run
```

Open Trends, pick "Speed (down)" in the metric picker on a network with no full check recorded, and confirm the empty state names the Full check button.

- [ ] **Step 3: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/HistoryView.swift
git commit -m "fix(gui): empty Trends charts now name a button, not a terminal

The speed hint said full checks don't happen and the watcher uses
--quick. That was true until a full check became reachable from
Home and the menu bar. Adds a path-MTU case, which had been
falling through to the generic 'may be skipped' text."
```

## Task 8: Drop the watcher's redundant flag

`lib/launchd.sh` passes `--no-bufferbloat` alongside `--quick`, and `lib/bufferbloat.sh:20` already returns early under `--quick`. The flag does nothing and makes the plist look like it is making a choice it is not.

**Files:**
- Modify: `lib/launchd.sh:19-25`
- Test: `tests/test_sanity.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_sanity.bats`:

```bash
@test "the watcher plist does not pass a flag --quick already implies" {
  # --quick returns early from lib/bufferbloat.sh:20, so
  # --no-bufferbloat alongside it changes nothing and reads as a
  # decision the plist is not actually making.
  run grep -c -- '--no-bufferbloat' "$REPO/lib/launchd.sh"
  [ "$output" = "0" ]
}

@test "the watcher plist still runs a quick, quiet, non-interactive check" {
  # The flags that do carry weight: --quick for speed, --no-gping so a
  # background job never blocks on a prompt, --quiet so the stdout log
  # stays readable.
  for flag in --quick --no-gping --quiet; do
    run grep -q -- "$flag" "$REPO/lib/launchd.sh"
    [ "$status" -eq 0 ] || { echo "watcher plist lost $flag"; return 1; }
  done
}
```

> `REPO` is already set by `tests/test_sanity.bats`'s `setup()`. If the file's setup uses a different variable name for the repo root, use that one instead — check the top of the file before running.

- [ ] **Step 2: Run to verify the first test fails**

```bash
bats tests/test_sanity.bats
```

Expected: "the watcher plist does not pass a flag --quick already implies" FAILS with output `1`.

- [ ] **Step 3: Remove the flag**

In `lib/launchd.sh`, delete this line from the `ProgramArguments` array:

```
    <string>--no-bufferbloat</string>
```

- [ ] **Step 4: Run to verify both pass**

```bash
bats tests/test_sanity.bats && shellcheck -x bin/netdiag lib/*.sh
```

Expected: all PASS, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add lib/launchd.sh tests/test_sanity.bats
git commit -m "fix: drop the watcher's redundant --no-bufferbloat

--quick already returns early from lib/bufferbloat.sh:20, so the
flag changed nothing and made the plist look like it was making a
choice it wasn't. Pins the three flags that do matter."
```

---

# Item 3 — `--summary` becomes per-network and honest

## Task 9: Establish a test file and fix the two pure defects

**Files:**
- Create: `tests/test_summary.bats`
- Modify: `helpers/summary.py:78,120`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_summary.bats`:

```bash
#!/usr/bin/env bats
#
# `netdiag --summary` — the aggregate over ~/net-diag/baseline.jsonl.
#
# This surface had drifted furthest from the rest of the tool: it blended
# every network into one distribution, summed a rolling one-hour window
# across overlapping runs, and printed numbers without judging any of
# them. These tests pin the corrected behaviour.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  STORE="$BATS_TEST_TMPDIR/baseline.jsonl"
  : > "$STORE"
}

# Append one record. $1 timestamp, $2 network id, $3.. extra JSON fragments.
rec() {
  local ts="$1" nid="$2"; shift 2
  local extra=""
  for frag in "$@"; do extra="${extra},${frag}"; done
  printf '{"timestamp":"%s","network":{"id":"%s"}%s}\n' "$ts" "$nid" "$extra" >> "$STORE"
}

# Run summary.py directly with a wide window so fixture timestamps land
# inside it regardless of when the suite runs.
summarise() {
  python3 "$REPO/helpers/summary.py" --history "$STORE" --window "${1:-999999}"
}

# A timestamp inside any sane window — "now", so --window always covers it.
now_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

@test "a single-sample metric says 'sample', not 'samples'" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"(1 sample)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"(1 samples)"* ]] || { echo "$output"; return 1; }
}

@test "two samples still say 'samples'" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":7.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"(2 samples)"* ]] || { echo "$output"; return 1; }
}

@test "a long diagnosis is wrapped, not cut off mid-advice" {
  # The CLI writes the fix into the second half of the sentence. Cutting
  # at 80 characters reliably threw the actionable part away.
  local long='Your Mac is losing packets to your router and the fix is to unplug the router for thirty seconds and plug it back in again'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" \
    "\"diagnosis\":[{\"severity\":\"critical\",\"summary\":\"$long\"}]"
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" != *"…"* ]] || { echo "still truncating:"; echo "$output"; return 1; }
  [[ "$output" == *"plug it back in again"* ]] || {
    echo "the advice did not survive:"; echo "$output"; return 1
  }
}
```

- [ ] **Step 2: Run to verify all three fail**

```bash
bats tests/test_summary.bats
```

Expected: all three FAIL — `(1 samples)` present, `…` present, tail of the advice missing.

- [ ] **Step 3: Fix pluralisation**

In `helpers/summary.py`, replace the `stats` function (line 74-78) with:

```python
def plural(n: int, noun: str) -> str:
    """'1 sample' / '2 samples'. The GUI's Trends counts were corrected
    for exactly this in 3e5ca0b; the CLI's were missed."""
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def stats(label: str, values: list[float | int], unit: str = "") -> str:
    if not values:
        return f"  {label:24s}  no data"
    lo, med, hi = min(values), statistics.median(values), max(values)
    return (f"  {label:24s}  {fmt_val(lo)}{unit} / {fmt_val(med)}{unit} / "
            f"{fmt_val(hi)}{unit}   ({plural(len(values), 'sample')})")
```

- [ ] **Step 4: Fix truncation**

Add `import textwrap` to the imports at the top of `helpers/summary.py`, then replace the diagnosis-printing loop (lines 116-121):

```python
        # Top recurring diagnosis summaries
        from collections import Counter
        all_summaries = [d.get("summary", "") for r in incidents for d in r.get("diagnosis", [])]
        for summary, n in Counter(all_summaries).most_common(5):
            short = summary[:80] + ("…" if len(summary) > 80 else "")
            print(f"     × {n:3d}  {short}")
```

with:

```python
        # Top recurring diagnosis summaries, wrapped rather than cut. The
        # CLI writes the fix into the back half of each sentence — "…the
        # box that…", advice following — so an 80-character truncation
        # reliably threw away the only actionable part.
        from collections import Counter
        all_summaries = [d.get("summary", "") for r in incidents for d in r.get("diagnosis", [])]
        for summary, n in Counter(all_summaries).most_common(5):
            lines = textwrap.wrap(summary, width=DIAGNOSIS_WRAP_COLS) or [""]
            print(f"     × {n:3d}  {lines[0]}")
            for continuation in lines[1:]:
                print(f"            {continuation}")
```

And add this constant just below the imports:

```python
# Prose wrapping width. Not a threshold — nothing is judged against it and
# no diagnosis depends on it; it is the shape of a paragraph, which is why
# it lives here rather than in lib/thresholds.sh.
DIAGNOSIS_WRAP_COLS = 68
```

- [ ] **Step 5: Run to verify all three pass**

```bash
bats tests/test_summary.bats
```

Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add helpers/summary.py tests/test_summary.bats
git commit -m "fix: --summary wrapped its advice away and miscounted samples

Diagnoses were cut at 80 characters, which lands mid-sentence in
every rule the CLI writes — the numbers survived and the fix did
not. They now wrap.

'(1 samples)' matched a bug already fixed on the GUI side in
3e5ca0b. Adds tests/test_summary.bats, which did not exist."
```

## Task 10: Report the busiest hour, not a sum

`wifi_disconnects.count` counts events in the past `WIFI_DISCONNECT_WINDOW_HOURS` — **1** (`lib/globals.sh:42`) — recomputed every run. `summary.py:155` sums it across every run in the window, so twelve runs over 24 h re-count the same hour twelve times. A live run of `--summary` on this machine reported **173 events**.

**Files:**
- Modify: `helpers/summary.py:154-156`
- Test: `tests/test_summary.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_summary.bats`:

```bash
@test "disconnects report the busiest single run, never a sum" {
  # wifi_disconnects.count covers a rolling 1h window
  # (WIFI_DISCONNECT_WINDOW_HOURS in lib/globals.sh) and is recomputed
  # per run. Three runs 15 minutes apart, each seeing the same 5
  # events, describe 5 disconnects — not 15.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"wifi_disconnects":{"count":5}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" != *"15"* ]] || { echo "still summing:"; echo "$output"; return 1; }
  [[ "$output" == *"busiest hour"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"5 disconnect"* ]] || { echo "$output"; return 1; }
}

@test "no disconnect data at all says so rather than reporting zero" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"no data"* ]] || { echo "$output"; return 1; }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
bats tests/test_summary.bats
```

Expected: "disconnects report the busiest single run" FAILS — output contains `15`.

- [ ] **Step 3: Replace the sum with a max**

In `helpers/summary.py`, replace:

```python
    # WiFi disconnect totals
    dc_total = sum(get_nested(r, "wifi_disconnects.count") or 0 for r in in_window)
    print(f"  WiFi disconnect events:    {dc_total} (summed over {len(in_window)} runs)")
```

with:

```python
    # WiFi disconnects: a maximum, never a sum.
    #
    # wifi_disconnects.count is a count of events in the past
    # WIFI_DISCONNECT_WINDOW_HOURS (1, lib/globals.sh:42), recomputed on
    # every run. Summing it across a 24h window adds twelve overlapping
    # one-hour views of the same events together — this printed "173" on a
    # laptop that had seen nothing like 173 disconnects. The worst single
    # window is a real quantity; the sum is not a quantity of anything.
    dc_counts = [c for r in in_window
                 if isinstance(c := get_nested(r, "wifi_disconnects.count"), int)]
    if dc_counts:
        worst = max(dc_counts)
        print(f"  WiFi disconnects:          busiest hour: "
              f"{plural(worst, 'disconnect')} "
              f"(worst of {plural(len(dc_counts), 'run')})")
    else:
        print("  WiFi disconnects:          no data")
```

- [ ] **Step 4: Run to verify both pass**

```bash
bats tests/test_summary.bats
```

Expected: 5 PASS.

- [ ] **Step 5: Sanity-check against the real store**

```bash
./bin/netdiag --summary | grep -i disconnect
```

Expected: a "busiest hour: N disconnects" line where N is plausible for one hour — single or low double digits, not 173.

- [ ] **Step 6: Commit**

```bash
git add helpers/summary.py tests/test_summary.bats
git commit -m "fix: --summary invented a disconnect count out of overlap

wifi_disconnects.count covers a rolling 1h window and is recomputed
every run, so summing it across a 24h window counts the same events
once per run that saw them. A real run on this machine reported 173
disconnects; twelve overlapping hours of roughly fifteen.

Reports the busiest single window instead, which is a quantity of
something, and says 'no data' rather than 0 when nothing recorded
it."
```

## Task 11: Group by network

**Files:**
- Modify: `helpers/summary.py` (`main`)
- Test: `tests/test_summary.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_summary.bats`:

```bash
@test "two networks get two blocks, and their metrics do not mix" {
  # Everything else in this tool is per-network — baselines, --show's
  # comparison, the Networks tab. A blended min/med/max across home and
  # a cafe describes neither.
  rec "$(now_ts)" "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:ssid=Cafe,mac=11:22:33:44:55:66" '"gateway":{"rtt_avg_ms":90.0}'
  run summarise
  [ "$status" -eq 0 ]
  # Two network headings.
  local headings
  headings="$(printf '%s\n' "$output" | grep -c '^── ')"
  [ "$headings" = "2" ] || { echo "expected 2 network blocks, got $headings"; echo "$output"; return 1; }
  # Neither block may show the other's figure as its own min or max.
  local home_block
  home_block="$(printf '%s\n' "$output" | awk '/^── .*Home/{f=1;next} /^── /{f=0} f')"
  [[ "$home_block" != *"90.0"* ]] || {
    echo "the cafe's RTT leaked into Home's distribution:"; echo "$home_block"; return 1
  }
}

@test "runs recorded under --redact are excluded, as they are from --history" {
  # A masked record's network.id is the literal 'wifi:mac=[redacted]',
  # shared with every other redacted run on every machine. history.py
  # drops these for that reason; summary must agree or the two disagree
  # about what a network is.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"rtt_avg_ms":5.0}'
  rec "$(now_ts)" "wifi:mac=[redacted]" '"gateway":{"rtt_avg_ms":999.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" != *"999"* ]] || { echo "a redacted run was counted:"; echo "$output"; return 1; }
}

@test "a network is labelled by its own name, not its group key" {
  rec "$(now_ts)" "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff" '"network":{"id":"wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff","label":"Home"},"gateway":{"rtt_avg_ms":5.0}'
  run summarise
  [ "$status" -eq 0 ]
  [[ "$output" == *"Home"* ]] || { echo "$output"; return 1; }
}
```

> Note the third test passes `"network":{…}` a second time as an extra fragment. `rec` writes the positional `network` object first, so the later one wins in the JSON object — which is what gives it a `label`. If your `json.loads` rejects the duplicate key, change `rec` to accept an optional label instead; the assertion is what matters.

- [ ] **Step 2: Run to verify they fail**

```bash
bats tests/test_summary.bats
```

Expected: the grouping and redaction tests FAIL — one block, and the 999 present.

- [ ] **Step 3: Reuse `history.py`'s grouping**

`helpers/history.py` imports cleanly with no side effects and exposes `group_key`, `clean`, `is_redacted` and `PLACEHOLDERS` — verified 2026-08-25. Reuse it rather than reimplementing, so `--summary` and `--history` can never disagree about what one network is.

> Deliberately **not** routed through `lib/netid.sh`'s `netid_group`. `tests/test_history.bats:116` asserts those two agree and fails on `main` today (tracker `NET.2`). Importing `group_key` means `--summary` inherits `--history`'s grouping whatever it turns out to be, rather than silently picking a side.

Add to the imports at the top of `helpers/summary.py`:

```python
# Same directory, so a plain import works when this is run as
# `python3 helpers/summary.py`. Verified side-effect-free at import.
from history import group_key, clean, is_redacted
```

Then restructure `main()`. After the `in_window` list is built (line 99), insert the exclusion and the grouping:

```python
    # A --redact run carries network.id "wifi:mac=[redacted]", shared with
    # every other redacted run on every machine, so it can never join a
    # real group. helpers/history.py drops these for the same reason; if
    # the two disagreed, --summary and --history would report different
    # numbers of networks from one file.
    in_window = [r for r in in_window if not is_redacted(r)]
    if not in_window:
        print(f"No runs in the last {args.window}h.")
        return

    # One bucket per network, insertion-ordered so the block order follows
    # first appearance in the file, which is chronological.
    buckets: dict[str, list[dict]] = {}
    labels: dict[str, str] = {}
    for r in in_window:
        key, _ = group_key(r)
        buckets.setdefault(key, []).append(r)
        # Prefer a real label over a placeholder, and the most recent real
        # one over an older one — an SSID that only became visible later
        # still names the whole group.
        if label := clean(get_nested(r, "network.label")):
            labels[key] = label
```

Move everything from the `print(f"netdiag summary …")` header through the disconnect line into a new function that takes one bucket:

```python
def report_network(label: str, records: list[dict]) -> None:
    """One network's block. Every figure here is scoped to `records`."""
    first_ts = parse_ts(records[0].get("timestamp"))
    last_ts = parse_ts(records[-1].get("timestamp"))

    print()
    print(f"── {label} — {plural(len(records), 'run')} ──")
    if first_ts and last_ts:
        print(f"  span: {first_ts.isoformat()} → {last_ts.isoformat()}")
    print()

    # ... the existing incidents block, metric block, categorical block
    #     and disconnect block, verbatim, with `in_window` renamed to
    #     `records` throughout ...
```

and drive it from `main()`:

```python
    print(f"netdiag summary — last {args.window}h "
          f"({plural(len(in_window), 'run')} across "
          f"{plural(len(buckets), 'network')})")

    for key, records in buckets.items():
        report_network(labels.get(key, key), records)
```

Since each block is now one network, the `distinct ISPs seen` line becomes per-network — which is the point. Leave it in place; it now answers "did this network's ISP change under me?" instead of "how many places have I been?".

- [ ] **Step 4: Run to verify they pass**

```bash
bats tests/test_summary.bats
```

Expected: 8 PASS.

- [ ] **Step 5: Sanity-check against the real store**

```bash
./bin/netdiag --summary
```

Expected: a header naming a run count and a network count, then one `── <name> — N runs ──` block per network, each with its own distributions.

- [ ] **Step 6: Commit**

```bash
git add helpers/summary.py tests/test_summary.bats
git commit -m "fix: --summary blended every network into one distribution

Baselines, --show's comparison and the Networks tab are all
per-network; --summary alone averaged home and a cafe together and
called the result your connection. One block per network now,
grouped by history.py's own group_key so the two can never
disagree about what one network is, and excluding --redact runs
for the same reason history.py does.

Routes through history.py rather than lib/netid.sh deliberately:
those two disagree today (tests/test_history.bats:116, tracker
NET.2) and this inherits --history's answer rather than picking a
side."
```

## Task 12: Judge the numbers

`--summary` is the only user-facing surface in the tool that prints numbers without saying whether any of them is good. This makes `helpers/summary.py` a **fourth** consumer of `lib/thresholds.sh`, so the drift guard and `CLAUDE.md` must be updated in the same commit or the project's central rule quietly stops covering everything.

**Files:**
- Modify: `helpers/summary.py`, `bin/netdiag:564-568`, `CLAUDE.md`, `tests/test_thresholds.bats`
- Test: `tests/test_summary.bats`, `tests/test_thresholds.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_summary.bats`:

```bash
# Judging needs the cutoffs, which arrive through the environment exactly
# as history.py's do.
summarise_judged() {
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export LOSS_WARN_PCT LOSS_CRIT_PCT THRESH_LATENCY_JITTER_WARN_MS \
         THRESH_NTP_DRIFT_WARN_S THRESH_NTP_DRIFT_CRIT_S \
         THRESH_MTU_STANDARD THRESH_WIFI_RSSI_WEAK_DBM \
         THRESH_BUFFERBLOAT_B_MS
  python3 "$REPO/helpers/summary.py" --history "$STORE" --window "${1:-999999}"
}

@test "a clean metric is marked clean" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"✓"* ]] || { echo "$line"; return 1; }
}

@test "a metric whose median is past the critical cutoff is marked critical" {
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":100.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"×"* ]] || { echo "$line"; return 1; }
}

@test "a clean median with a bad max says so on the same line" {
  # The glyph judges the median — the typical case — but a run that hit
  # 100% loss is the thing the user came to find, so the max is named.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":100.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'gateway loss')"
  [[ "$line" == *"✓"* ]] || { echo "median is clean, expected a tick: $line"; return 1; }
  [[ "$line" == *"max"* ]] || { echo "the 100% run was not named: $line"; return 1; }
}

@test "a metric with no samples takes no glyph at all" {
  # Absence of a measurement is not a verdict — the same rule the Report
  # card's grey minus.circle follows.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run summarise_judged
  [ "$status" -eq 0 ]
  local line
  line="$(printf '%s\n' "$output" | grep 'NTP drift')"
  [[ "$line" == *"no data"* ]] || { echo "$line"; return 1; }
  [[ "$line" != *"✓"* ]] || { echo "unmeasured metric claimed health: $line"; return 1; }
}

@test "summary.py refuses to judge without the thresholds" {
  # Same contract history.py holds: a Python default would be a second
  # home for a number that has exactly one, and a stale second copy
  # still produces a plausible verdict.
  rec "$(now_ts)" "wifi:mac=aa:bb:cc:dd:ee:ff" '"gateway":{"loss_pct":0.0}'
  run env -u LOSS_WARN_PCT -u LOSS_CRIT_PCT \
    python3 "$REPO/helpers/summary.py" --history "$STORE" --window 999999
  [ "$status" -eq 3 ]
  [[ "$output" == *"LOSS_WARN_PCT"* ]]
  [[ "$output" == *"lib/thresholds.sh"* ]]
}
```

And append to `tests/test_thresholds.bats`:

```bash
@test "helpers/summary.py carries no inline numeric cutoff either" {
  # --summary now judges each metric line, so this file is the fourth
  # thing in the project that decides whether a number is normal. Same
  # guard as the history.py one above, same reasoning: a cutoff creeping
  # back as a Python literal is a number lib/thresholds.sh would never
  # reflect a change to.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/summary.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in summary.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in summary.py" {
  cp "$REPO/helpers/summary.py" "$BATS_TEST_TMPDIR/planted_summary.py"
  printf '\nif False:\n    pass  # if loss >= 20:\n' >> "$BATS_TEST_TMPDIR/planted_summary.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_summary.py"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
bats tests/test_summary.bats tests/test_thresholds.bats
```

Expected: the five judging tests FAIL (no glyphs, exit 0 without thresholds). The two threshold-guard tests may pass already — `summary.py` has no cutoffs *yet*. That is fine; they exist to fail the moment step 3 gets it wrong.

- [ ] **Step 3: Add judging to `summary.py`**

Add near the top of `helpers/summary.py`, after the constants:

```python
def _require_threshold(name: str) -> float:
    """Read one cutoff from the environment, or refuse to run.

    No defaults, ever. A default here would be a second home for a number
    that has exactly one home (lib/thresholds.sh), and a stale second copy
    still produces a plausible verdict — the failure nobody notices. Same
    contract helpers/history.py holds for THRESH_COMPARE_*.
    """
    raw = os.environ.get(name)
    if raw is None or raw == "":
        sys.exit(f"summary.py: {name} is not set — it comes from "
                 f"lib/thresholds.sh, which is the only place a cutoff lives")
    try:
        return float(raw)
    except ValueError:
        sys.exit(f"summary.py: {name} is not a number (got: {raw!r}) — "
                 f"see lib/thresholds.sh")


OK, WARN, CRIT = "✓", "⚠", "×"   # ✓ ⚠ ×


def judge(value: float, warn: float, crit: float, higher_is_worse: bool = True) -> str:
    """One glyph for one number, against two cutoffs from thresholds.sh.

    The comparisons here are against named parameters, never literals —
    tests/test_thresholds.bats greps this file for a bare number beside a
    comparison operator and fails the build on one.
    """
    if higher_is_worse:
        if value >= crit:
            return CRIT
        if value >= warn:
            return WARN
        return OK
    if value <= crit:
        return CRIT
    if value <= warn:
        return WARN
    return OK
```

Add `import os` to the imports.

Then give `stats()` an optional judging pair, and mark the max when it is worse than the median's verdict:

```python
def stats(label: str, values: list[float | int], unit: str = "",
          warn: float | None = None, crit: float | None = None,
          higher_is_worse: bool = True) -> str:
    if not values:
        # Absence of a measurement is not a verdict. Same rule the Report
        # card follows when it renders a grey minus.circle instead of a
        # green dot on a row that was never measured.
        return f"     {label:24s}  no data"
    lo, med, hi = min(values), statistics.median(values), max(values)
    body = (f"{fmt_val(lo)}{unit} / {fmt_val(med)}{unit} / {fmt_val(hi)}{unit}"
            f"   ({plural(len(values), 'sample')})")
    if warn is None or crit is None:
        return f"     {label:24s}  {body}"

    # The glyph judges the median — the typical case, which is what a
    # distribution summary is for. A worse extreme is named rather than
    # promoted: "usually fine, once terrible" is the true sentence, and
    # letting the max own the glyph would make one bad minute in a month
    # read as a broken network.
    glyph = judge(med, warn, crit, higher_is_worse)
    worst = judge(hi if higher_is_worse else lo, warn, crit, higher_is_worse)
    if worst != glyph:
        extreme = hi if higher_is_worse else lo
        body += f"   {worst} {'max' if higher_is_worse else 'min'} {fmt_val(extreme)}{unit}"
    return f"  {glyph}  {label:24s}  {body}"
```

Finally, in `report_network`, pass the cutoffs. Read them once at module level in `main()` and hand them down, or read them inside `report_network` — either is fine, but read them through `_require_threshold` so the refusal contract holds:

```python
    print("     metric                    min / med / max")
    print(stats("gateway RTT (ms)", metric("gateway.rtt_avg_ms")))
    print(stats("gateway loss (%)", metric("gateway.loss_pct"),
                warn=_require_threshold("LOSS_WARN_PCT"),
                crit=_require_threshold("LOSS_CRIT_PCT")))
    print(stats("bufferbloat gw Δ (ms)", metric("bufferbloat.gw_delta_ms"),
                warn=_require_threshold("THRESH_BUFFERBLOAT_B_MS"),
                crit=_require_threshold("THRESH_BUFFERBLOAT_C_MS")))
    print(stats("bufferbloat inet Δ (ms)", metric("bufferbloat.inet_delta_ms"),
                warn=_require_threshold("THRESH_BUFFERBLOAT_B_MS"),
                crit=_require_threshold("THRESH_BUFFERBLOAT_C_MS")))
    print(stats("WiFi RSSI (dBm)", metric("wifi.rssi"),
                warn=_require_threshold("THRESH_WIFI_RSSI_G1_DBM"),
                crit=_require_threshold("THRESH_WIFI_RSSI_WEAK_DBM"),
                higher_is_worse=False))
    print(stats("path MTU", metric("mtu.effective"),
                warn=_require_threshold("THRESH_MTU_STANDARD"),
                crit=_require_threshold("THRESH_MTU_CRIT"),
                higher_is_worse=False))
    print(stats("NTP drift (s)", metric("ntp.drift_seconds"),
                warn=_require_threshold("THRESH_NTP_DRIFT_WARN_S"),
                crit=_require_threshold("THRESH_NTP_DRIFT_CRIT_S")))
    # Throughput has no absolute cutoff — "slow" is relative to what this
    # link has done before, which is BL-1's job in --show, not a number
    # that could live in thresholds.sh. Reported unjudged, deliberately.
    print(stats("speedtest down (Mbps)", metric("speedtest.down_mbps")))
    print(stats("speedtest up   (Mbps)", metric("speedtest.up_mbps")))
```

> `THRESH_BUFFERBLOAT_B_MS` (30) / `THRESH_BUFFERBLOAT_C_MS` (60) are the existing B/C grade boundaries — a B is fine, a C is where it starts hurting. All values verified present in `lib/thresholds.sh` on 2026-08-25.
>
> **RSSI ordering — an earlier draft of this plan had it backwards.** With
> `higher_is_worse=False`, `judge` tests `value <= crit` first, so `crit`
> must be the *more negative* number. `THRESH_WIFI_RSSI_WEAK_DBM` is -75 and
> `THRESH_WIFI_RSSI_G1_DBM` is -70, and -75 is the worse signal. So
> `warn=THRESH_WIFI_RSSI_G1_DBM`, `crit=THRESH_WIFI_RSSI_WEAK_DBM`. The
> reverse assignment makes every reading below -70 critical and leaves the
> warn band unreachable — because -72 satisfies `<= -70` just as -80 does.
> The two cutoffs are documented in `tests/test_thresholds.bats` as meaning
> different things, and that comment is about which *rule* fires, not about
> which is the worse signal; do not read the ordering out of it.
>
> The equivalent check for MTU comes out the other way and the original
> assignment was right: `THRESH_MTU_CRIT` (1280) is lower than
> `THRESH_MTU_STANDARD` (1400), and a lower MTU is worse, so `crit=1280`
> already is the more-negative-equivalent.

- [ ] **Step 4: Export the thresholds from the CLI**

In `bin/netdiag`, the `--summary` dispatch block (line 564) currently reads:

```sh
if [ "$SUMMARY" -eq 1 ]; then
  python3 "$HELPERS_DIR/summary.py" \
    --history "$LOG_DIR/baseline.jsonl" \
    --window "$SUMMARY_WINDOW_HOURS" || exit 3
  exit 0
fi
```

Replace with:

```sh
if [ "$SUMMARY" -eq 1 ]; then
  # --summary now judges each metric line, so it needs the cutoffs, and
  # they reach Python through the environment exactly as --history's and
  # --show's do. The helper refuses to start without them rather than
  # carrying a default — see summary.py's _require_threshold.
  # shellcheck source=lib/thresholds.sh
  . "$LIB_DIR/thresholds.sh"
  export LOSS_WARN_PCT LOSS_CRIT_PCT THRESH_BUFFERBLOAT_B_MS \
         THRESH_BUFFERBLOAT_C_MS THRESH_WIFI_RSSI_WEAK_DBM \
         THRESH_WIFI_RSSI_G1_DBM THRESH_MTU_STANDARD THRESH_MTU_CRIT \
         THRESH_NTP_DRIFT_WARN_S THRESH_NTP_DRIFT_CRIT_S
  python3 "$HELPERS_DIR/summary.py" \
    --history "$LOG_DIR/baseline.jsonl" \
    --window "$SUMMARY_WINDOW_HOURS" || exit 3
  exit 0
fi
```

- [ ] **Step 5: Update `CLAUDE.md`**

In the "Engineering constraints" section, the thresholds bullet currently names three consumers. Replace that bullet with:

```markdown
- **Thresholds live in `lib/thresholds.sh`, nowhere else.** Four things now
  judge a network — `lib/diagnosis.sh` (one verdict per scan),
  `lib/monitor.sh` (one every few seconds), `helpers/history.py` (one per
  metric, per stored run) and `helpers/summary.py` (one per metric, per
  network, over a window) — and if they drift the app shows a green dot
  over a red report. `tests/test_thresholds.bats` fails the build on an
  inline numeric cutoff in any of the four.
```

While in `CLAUDE.md`, correct the `--redact` description in the Workflow section. It reads as though the ISP is masked; `helpers/emit_json.py:275` deliberately keeps ISP and ASN, because they name a provider and that is what makes a report worth reading. Change:

```
a plain run puts the machine's public IPv6 address, ISP and city in the sample
```

to:

```
a plain run puts the machine's public IPv6 address and city in the sample
(the ISP name is kept even under `--redact` — it names a provider, which
is what makes the report useful to read)
```

- [ ] **Step 6: Run everything**

```bash
bats tests/test_summary.bats tests/test_thresholds.bats && \
  shellcheck -x bin/netdiag lib/*.sh && \
  ./bin/netdiag --summary | head -30
```

Expected: all bats PASS, shellcheck silent, and the live summary shows `✓` / `⚠` / `×` glyphs against real metrics.

- [ ] **Step 7: Commit**

```bash
git add helpers/summary.py bin/netdiag CLAUDE.md \
        tests/test_summary.bats tests/test_thresholds.bats
git commit -m "feat: --summary now says whether a number is good

It was the only user-facing surface in the tool that printed
figures and judged none of them — 'gateway loss 0.0 / 0.0 / 100.0'
read exactly as flat as a healthy line.

The glyph judges the median, because that is what a distribution
summary is for; a worse max is named on the same line rather than
promoted, so one bad minute in a month does not read as a broken
network. An unmeasured metric takes no glyph, matching the Report
card's grey minus.circle.

This makes summary.py a fourth consumer of lib/thresholds.sh, so
CLAUDE.md's rule and the drift guard now name four files. The
helper refuses to start without the cutoffs rather than carrying a
default.

Also corrects CLAUDE.md's --redact description: the ISP is kept by
design (emit_json.py:275), not masked."
```

---

# Item 2 — `netdiag --share`

## Task 13: The read-time redactor

**Files:**
- Create: `helpers/share.py`
- Create: `tests/test_share.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/test_share.bats`:

```bash
#!/usr/bin/env bats
#
# `netdiag --share` — one run as pasteable plain text.
#
# The reason this exists rather than reusing --redact: lib/output.sh
# deliberately stores every run unredacted (it saves REDACT, forces 0,
# restores), and helpers/history.py drops --redact runs from the store
# entirely. So there is no redacted stored copy to read, and redaction of
# a stored run has to happen at read time.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  RUN="$BATS_TEST_TMPDIR/run.json"
  cat > "$RUN" <<'JSON'
{
  "timestamp": "2026-08-25T12:00:00Z",
  "run_id": "2026-08-25-120000",
  "network": {"id": "wifi:ssid=MyHouse,mac=aa:bb:cc:dd:ee:ff", "label": "MyHouse"},
  "interface": {"name": "en0", "type": "Wi-Fi", "ip": "192.168.15.42",
                "gateway": "192.168.15.1", "gateway_mac": "aa:bb:cc:dd:ee:ff"},
  "public": {"ip": "203.0.113.77", "isp": "Example Telecom SA",
             "asn": "AS64496", "city": "Recife", "country": "Brazil",
             "country_iso": "BR"},
  "wifi": {"ssid": "MyHouse", "bssid": "aa:bb:cc:dd:ee:f0", "channel": 52,
           "rssi": -55},
  "ipv6": {"available": true, "global_addr": "2001:db8:1234:5678::1",
           "gateway": "fe80::a8bb:ccff:fedd:eeff"},
  "gateway": {"ip": "192.168.15.1", "loss_pct": 0.0, "rtt_avg_ms": 7.6},
  "internet_latency": {"rtt_avg_ms": 55.0, "loss_pct": 0.0},
  "mtu": {"effective": 1500},
  "diagnosis": [
    {"severity": "warn", "rule": "WS-1",
     "summary": "Your WiFi channel is crowded on MyHouse at 203.0.113.77."}
  ]
}
JSON
}

share() { python3 "$REPO/helpers/share.py" < "$RUN"; }

@test "no identifying value survives into the shared text" {
  run share
  [ "$status" -eq 0 ]
  for secret in "203.0.113.77" "MyHouse" "aa:bb:cc:dd:ee:ff" \
                "aa:bb:cc:dd:ee:f0" "2001:db8:1234:5678::1" \
                "fe80::a8bb:ccff:fedd:eeff" "192.168.15.42" "Recife"; do
    [[ "$output" != *"$secret"* ]] || {
      echo "leaked: $secret"; echo "$output"; return 1
    }
  done
}

@test "identifying values are masked inside prose, not just in their own fields" {
  # Diagnosis summaries interpolate these values into sentences, so
  # nulling the field alone would leave the same string in the text
  # beside it. This is why the scrub is a substring pass over the whole
  # tree rather than a field-by-field blank.
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"[redacted]"* ]] || { echo "$output"; return 1; }
}

@test "the ISP and the RFC1918 gateway are deliberately kept" {
  # ISP and ASN name a provider, which is what makes the report worth
  # reading. A 192.168.x.y identifies nobody and blanking it would gut
  # the router rows.
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Example Telecom SA"* ]] || { echo "ISP was masked"; echo "$output"; return 1; }
  [[ "$output" == *"192.168.15.1"* ]] || { echo "gateway was masked"; echo "$output"; return 1; }
}

@test "the country is kept — two letters are too short to scrub safely" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Brazil"* ]] || { echo "$output"; return 1; }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
bats tests/test_share.bats
```

Expected: all FAIL — `helpers/share.py` does not exist.

- [ ] **Step 3: Write the redactor half**

Create `helpers/share.py`:

```python
#!/usr/bin/env python3
"""Render one netdiag run as pasteable plain text, with identifying values
masked at read time.

Why this exists rather than a flag on --redact: `lib/output.sh` deliberately
stores every run *unredacted* (it saves REDACT, forces it to 0 to build the
record it appends to history, then restores it), and `helpers/history.py`
drops --redact runs from the store entirely, because a masked record's
network.id is the literal "wifi:mac=[redacted]" and can never be grouped
with a real network. So there is no redacted stored copy to read, and
redaction of a stored run has to happen here, at read time, sourced from
the record's own fields.

Input:  one run's JSON on stdin, or --file PATH.
Output: plain text on stdout. No ANSI, no colours — the point is that it
        pastes into a support chat, a forum post or a ticket.
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap
from typing import Any

REDACTED = "[redacted]"

# The record paths whose values identify a person or a place. This mirrors
# helpers/emit_json.py's _REDACT_ENV exactly, and its exclusions are
# reasoned and load-bearing:
#
#   * public.isp / public.asn are KEPT — they name a provider, which is
#     what the reader needs to reason about the fault.
#   * public.country / country_iso are KEPT — two characters is too short
#     to substring-replace without corrupting unrelated text.
#   * RFC1918 addresses are KEPT — a 192.168.x.y tells a reader nothing
#     about who you are, and blanking them would gut the router rows.
#   * network.id / network.label are absent deliberately: they are
#     composites of values already in this list ("wifi:ssid=Home,mac=…"),
#     so the identifying parts get masked anyway and the readable
#     structure survives. Listing them would turn a generic placeholder
#     like "unknown network" into a secret and blank it everywhere.
#
# Paths verified against examples/sample-output.json on 2026-08-25.
_IDENTIFYING_PATHS = (
    "public.ip",
    "public.city",
    "interface.ip",
    "interface.gateway_mac",
    "wifi.ssid",
    "wifi.bssid",
    "ipv6.global_addr",
    # Link-local and unroutable, but a fe80:: address is EUI-64-derived
    # from the router's MAC — leaving it in republishes the gateway_mac
    # sitting two lines above it.
    "ipv6.gateway",
)

# Substrings shorter than this are skipped: replacing them corrupts
# unrelated text rather than protecting anything. Same guard, same value
# as emit_json.py's.
_MIN_SECRET_LEN = 3


def get_nested(d: dict | None, path: str) -> Any:
    cur: Any = d
    for k in path.split("."):
        if cur is None or not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def secrets_in(record: dict) -> list[str]:
    """Every identifying string this record carries, longest first.

    Longest first matters: an SSID must be masked before a shorter value
    that happens to sit inside it, or the shorter replacement leaves a
    fragment of the longer one behind.
    """
    found = set()
    for path in _IDENTIFYING_PATHS:
        value = get_nested(record, path)
        if isinstance(value, str) and len(value) >= _MIN_SECRET_LEN:
            found.add(value)
    return sorted(found, key=len, reverse=True)


def scrub(node: Any, secrets: list[str]) -> Any:
    """Replace every secret substring anywhere in the structure.

    Field-by-field nulling is not enough on its own: diagnosis summaries
    and the baseline's regression descriptions interpolate these values
    into prose, so the same string has to be caught wherever it ended up.
    """
    if isinstance(node, dict):
        return {k: scrub(v, secrets) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v, secrets) for v in node]
    if isinstance(node, str):
        for s in secrets:
            node = node.replace(s, REDACTED)
        return node
    return node


def redact(record: dict) -> dict:
    return scrub(record, secrets_in(record))
```

Then the rendering half and `main()` — Task 14. For now, add a minimal `main()` so the redaction tests can run:

```python
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=None,
                    help="read the run from PATH instead of stdin")
    args = ap.parse_args()

    raw = open(args.file).read() if args.file else sys.stdin.read()
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"share.py: input is not valid JSON ({exc})")
    if not isinstance(record, dict):
        sys.exit("share.py: expected one run object, got "
                 f"{type(record).__name__}")

    print(render(redact(record)))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Add a placeholder `render` so the tests can run**

Immediately above `main()`, add:

```python
def render(record: dict) -> str:
    """Replaced in full by the next task. Dumping the redacted record is
    enough to prove the scrub works, and nothing ships between these two
    commits."""
    return json.dumps(record, indent=2)
```

- [ ] **Step 5: Run to verify the redaction tests pass**

```bash
bats tests/test_share.bats
```

Expected: 4 PASS.

- [ ] **Step 6: Commit**

```bash
git add helpers/share.py tests/test_share.bats
git commit -m "feat: add read-time redaction for a stored run

The app's only copy button emits raw JSON with the machine's public
IPv4 and IPv6 addresses, SSID, BSSID, gateway MAC and city in it.
--redact cannot be reused on a stored run: output.sh stores every
record unredacted by design, and history.py drops redacted ones
from the store entirely, so no redacted copy exists to read.

Mirrors emit_json.py's substring scrub, sourced from the record
instead of the environment, with its exclusions intact — ISP and
ASN kept because they name a provider, country kept because two
letters cannot be substring-replaced safely, RFC1918 kept because
it identifies nobody. Renders JSON for now; text lands next."
```

## Task 14: The text renderer

**Files:**
- Modify: `helpers/share.py`
- Modify: `tests/test_share.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_share.bats`:

```bash
@test "the shared report is plain text with no ANSI escapes" {
  run share
  [ "$status" -eq 0 ]
  # An ESC byte anywhere means a colour code survived into something
  # meant for a support chat.
  printf '%s' "$output" | grep -q $'\033' && {
    echo "ANSI escape in shared output"; return 1
  }
  # And it must not still be JSON.
  [[ "$output" != "{"* ]] || { echo "still emitting JSON"; return 1; }
}

@test "the shared report carries the report card and the diagnoses" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Report"* ]] || { echo "no report card"; echo "$output"; return 1; }
  [[ "$output" == *"What we found"* ]] || { echo "no diagnoses"; echo "$output"; return 1; }
  [[ "$output" == *"crowded"* ]] || { echo "diagnosis prose missing"; echo "$output"; return 1; }
}

@test "the shared report states the measurements a reader needs" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"7.6"* ]]  || { echo "gateway RTT missing"; return 1; }
  [[ "$output" == *"55"* ]]   || { echo "internet RTT missing"; return 1; }
  [[ "$output" == *"1500"* ]] || { echo "MTU missing"; return 1; }
}

@test "an unmeasured value says so rather than reporting zero" {
  # The CLI's schema draws this line deliberately: treating an unmeasured
  # value as zero is what produced false diagnoses in earlier versions.
  printf '{"timestamp":"2026-08-25T12:00:00Z","gateway":{},"diagnosis":[]}\n' > "$RUN"
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"0.0 ms"* ]] || { echo "reported an unmeasured value as zero"; return 1; }
}

@test "a run with no diagnoses says the network looked healthy" {
  printf '{"timestamp":"2026-08-25T12:00:00Z","gateway":{"rtt_avg_ms":5.0},"diagnosis":[]}\n' > "$RUN"
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing obviously wrong"* ]] || { echo "$output"; return 1; }
}

@test "malformed input fails with a usage error, never a traceback" {
  run bash -c "printf 'not json' | python3 '$REPO/helpers/share.py'"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"not valid JSON"* ]] || { echo "$output"; return 1; }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
bats tests/test_share.bats
```

Expected: the six new tests FAIL — output is still JSON.

- [ ] **Step 3: Replace the placeholder `render`**

In `helpers/share.py`, replace the placeholder `render` with:

```python
WRAP_COLS = 68


def _fmt(value: Any, suffix: str = "") -> str:
    """A number, or the honest absence of one.

    "not measured" rather than a zero. The CLI's schema draws that line
    deliberately — treating an unmeasured value as zero is what produced
    false diagnoses in earlier versions — and this renderer has to hold it
    too.
    """
    if value is None:
        return "not measured"
    if isinstance(value, float):
        return f"{value:g}{suffix}"
    return f"{value}{suffix}"


def _row(label: str, value: str) -> str:
    return f"  {label:22s}{value}"


def render(record: dict) -> str:
    """One run as plain text: the compact Report card and the CLI's own
    prose, and nothing else.

    Deliberately not the expert sections, matching the rule bin/netdiag
    already enforces for --redact (it forces EXPERT=0): the expert panel
    is where the identifying values live, and a partially redacted
    transcript is worse than none because it looks safe.

    Every sentence under "What we found" is the CLI's `summary` verbatim.
    Nothing here composes a verdict — that is lib/diagnosis.sh's job.
    """
    out: list[str] = []

    stamp = record.get("timestamp") or "unknown time"
    version = record.get("version") or ""
    header = f"netdiag report — {stamp}"
    if version:
        header += f" (netdiag {version})"
    out.append(header)
    out.append("")

    out.append("── Report ──")
    iface = record.get("interface") or {}
    link = " · ".join(p for p in (iface.get("name"), iface.get("type")) if p)
    out.append(_row("Network", link or "not measured"))

    gw = record.get("gateway") or {}
    gw_parts = [_fmt(gw.get("rtt_avg_ms"), " ms")]
    if (loss := gw.get("loss_pct")) is not None:
        gw_parts.append(f"{loss:g}% loss")
    out.append(_row("Router", " · ".join(gw_parts)))

    inet = record.get("internet_latency") or {}
    inet_parts = [_fmt(inet.get("rtt_avg_ms"), " ms")]
    if (loss := inet.get("loss_pct")) is not None:
        inet_parts.append(f"{loss:g}% loss")
    out.append(_row("Internet", " · ".join(inet_parts)))

    pub = record.get("public") or {}
    # ISP and country survive the scrub by design — they are what make the
    # report worth reading to someone trying to help.
    isp = " · ".join(p for p in (pub.get("isp"), pub.get("country")) if p)
    if isp:
        out.append(_row("Provider", isp))

    dns = record.get("dns") or []
    if dns:
        ok = sum(1 for d in dns if d.get("ok"))
        out.append(_row("Name lookups (DNS)", f"{ok} of {len(dns)} resolvers OK"))

    wifi = record.get("wifi") or {}
    if wifi:
        out.append(_row("Wi-Fi signal", _fmt(wifi.get("rssi"), " dBm")))

    bb = record.get("bufferbloat") or {}
    if grade := bb.get("gw_grade"):
        delta = bb.get("gw_delta_ms")
        out.append(_row("Under load",
                        f"grade {grade}" + (f" (+{delta:g} ms)" if delta is not None else "")))
    else:
        out.append(_row("Under load", "not measured"))

    mtu = record.get("mtu") or {}
    out.append(_row("Packet size (MTU)", _fmt(mtu.get("effective"), " bytes")))

    speed = record.get("speedtest") or {}
    if speed.get("down_mbps") is not None or speed.get("up_mbps") is not None:
        out.append(_row("Speed",
                        f"{_fmt(speed.get('down_mbps'))} Mbps down · "
                        f"{_fmt(speed.get('up_mbps'))} up"))
    else:
        out.append(_row("Speed", "not measured"))

    ntp = record.get("ntp") or {}
    drift = ntp.get("drift_seconds")
    out.append(_row("Clock",
                    "not measured" if drift is None else f"{drift:+.2f} s off"))

    out.append("")
    out.append("── What we found ──")
    diagnoses = record.get("diagnosis") or []
    if not diagnoses:
        out.append("  Nothing obviously wrong — the network looked healthy.")
    for d in diagnoses:
        # The CLI already writes this for a non-technical reader; rewording
        # it here would be a second opinion from a file that has no
        # business having one.
        summary = d.get("summary", "")
        rule = d.get("rule")
        marker = {"critical": "×", "warn": "⚠"}.get(d.get("severity", ""), "·")
        lines = textwrap.wrap(summary, width=WRAP_COLS) or [""]
        head = f"  {marker} {lines[0]}"
        if rule:
            head += f"   [{rule}]"
        out.append(head)
        for continuation in lines[1:]:
            out.append(f"    {continuation}")

    out.append("")
    out.append("Identifying values are masked. Generated by netdiag --share.")
    return "\n".join(out)
```

- [ ] **Step 4: Run to verify everything passes**

```bash
bats tests/test_share.bats
```

Expected: 10 PASS.

- [ ] **Step 5: Eyeball it against a real run**

```bash
./bin/netdiag --json --quick > /tmp/netdiag-run.json && \
  python3 helpers/share.py < /tmp/netdiag-run.json
```

Read the output as if you were pasting it to an ISP. Confirm there is no public IP, no SSID, no BSSID, no IPv6 address and no city anywhere in it, and that the ISP name and the diagnosis prose are present and readable.

- [ ] **Step 6: Commit**

```bash
git add helpers/share.py tests/test_share.bats
git commit -m "feat: render a run as pasteable plain text

The compact Report card and the CLI's own prose, no ANSI, no
expert sections — matching the rule bin/netdiag already enforces
for --redact, since the expert panel is where the identifying
values live.

Unmeasured values say 'not measured' rather than 0: treating the
two as the same is what produced false diagnoses in earlier
versions and the rule has to hold in a new renderer too. Every
sentence under 'What we found' is the CLI's summary verbatim."
```

## Task 15: Wire `--share` into the CLI

**Files:**
- Modify: `bin/netdiag` (globals, flag parsing, mode dispatch, `--help`)
- Modify: `CLAUDE.md` (CLI surface)
- Test: `tests/test_share.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_share.bats`:

```bash
@test "--share reads a run on stdin with '-'" {
  run bash -c "'$REPO/bin/netdiag' --share=- < '$RUN'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"── Report ──"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"203.0.113.77"* ]] || { echo "leaked the public IP"; return 1; }
}

@test "--share on an empty store fails as a usage error, not a diagnosis" {
  # Exit 2 is reserved for a real diagnosis so wrappers can tell the two
  # apart. 'you have no runs' is a 3.
  run env HOME="$BATS_TEST_TMPDIR" "$REPO/bin/netdiag" --share
  [ "$status" -eq 3 ]
  [[ "$output" == *"no stored run"* ]] || { echo "$output"; return 1; }
}

@test "--share is documented in --help" {
  run "$REPO/bin/netdiag" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--share"* ]]
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
bats tests/test_share.bats
```

Expected: the stdin and empty-store tests FAIL (unknown flag, exit 3 with the wrong message).

- [ ] **Step 3: Add the globals**

In `bin/netdiag`, beside the other mode globals (near `SHOW=0` / `SHOW_ID=""`, around line 180-200), add:

```sh
# --share renders one stored run — or one fed in on stdin — as plain
# text with identifying values masked, for pasting into a support chat.
# Distinct from --redact, which masks a run as it happens: the store
# deliberately keeps full detail (see lib/output.sh's REDACT save/restore),
# so sharing a *past* run has to redact at read time.
SHARE=0
SHARE_ID=""
```

- [ ] **Step 4: Add flag parsing**

In the flag `case` block, beside `--show`, add:

```sh
    --share)          SHARE=1 ;;
    --share=*)        SHARE=1; SHARE_ID="${1#--share=}" ;;
```

- [ ] **Step 5: Add mode dispatch**

Immediately after the `--show` dispatch block (which ends `exit 0; fi` around line 612), add:

```sh
if [ "$SHARE" -eq 1 ]; then
  # stdin: the app's path. It already holds the run's JSON and needs no
  # store lookup, so a run that finished two seconds ago shares exactly
  # like one from last week.
  if [ "$SHARE_ID" = "-" ]; then
    python3 "$HELPERS_DIR/share.py" || exit 3
    exit 0
  fi
  # Otherwise resolve a stored run through --show, which already knows how
  # to find one by id and how to pick sensibly. Its output is a wrapper
  # object; share.py wants the run itself.
  # shellcheck source=lib/thresholds.sh
  . "$LIB_DIR/thresholds.sh"
  export THRESH_COMPARE_MIN_SAMPLES THRESH_COMPARE_TAIL_PCTL NETDIAG_VERSION
  _share_id="$SHARE_ID"
  if [ -z "$_share_id" ]; then
    # Bare --share: the newest run in the store. --history's `runs` is a
    # flat top-level array (not nested inside `networks`), each row keyed
    # `id` and `ts` — verified against a live store on 2026-08-25.
    _share_id="$(python3 "$HELPERS_DIR/history.py" \
        --history "$LOG_DIR/baseline.jsonl" 2>/dev/null \
      | python3 -c 'import json, sys
try:
    runs = json.load(sys.stdin).get("runs") or []
except Exception:
    runs = []
runs.sort(key=lambda r: r.get("ts") or "")
print(runs[-1].get("id", "") if runs else "")' 2>/dev/null)"
    if [ -z "$_share_id" ]; then
      printf 'netdiag: no stored run to share yet — run a check first\n' >&2
      exit 3
    fi
  fi
  # --show returns {schema, version, id, run, context, comparison}; `run`
  # is the complete record as it was written. Verified 2026-08-25.
  python3 "$HELPERS_DIR/history.py" \
      --history "$LOG_DIR/baseline.jsonl" \
      --show "$_share_id" 2>/dev/null \
    | python3 -c 'import json, sys
doc = json.load(sys.stdin)
json.dump(doc["run"], sys.stdout)' 2>/dev/null \
    | python3 "$HELPERS_DIR/share.py" || {
      printf 'netdiag: no stored run to share (id: %s)\n' "$_share_id" >&2
      exit 3
    }
  exit 0
fi
```

> **These shapes are verified, not assumed.** Confirmed on a live store on
> 2026-08-25: `--history`'s runs live at `doc["runs"]` as a flat array —
> *not* nested under each network, and the network rows carry no `runs`
> key at all — with each row keyed `id` (e.g.
> `2026-08-25T05:19:22Z.9e93554e`) and `ts`, not `run_id`/`timestamp`.
> `--show=<id>` returns `{comparison, context, id, run, schema, version}`
> and `doc["run"]` carries `diagnosis`, `gateway`, `public` and the rest of
> the record. An earlier draft of this plan guessed `networks[].runs[]` and
> `run_id`; both were wrong.
>
> The thresholds are sourced *before* the id lookup because `history.py`
> refuses to start without `THRESH_COMPARE_*` — including for a plain
> `--history` listing, since every network row now carries `metric_stats`.

- [ ] **Step 6: Document it**

Add `--share` to `CLAUDE.md`'s CLI surface block so `tests/test_sanity.bats:74` covers it:

```
netdiag [TARGET] [--quick] [--quiet] [--json] [--expert] [--redact]
        ...
netdiag --watch[=SEC] | --summary[=HOURS] | --history[=N] | --show=ID
        | --share[=ID|-]
```

And add a paragraph beneath the surface block:

```markdown
`--share` is the pasteable form of a report: one run as plain text, no
colours, identifying values masked. It exists rather than being a flag on
`--redact` because `lib/output.sh` deliberately stores every run
*unredacted* and `helpers/history.py` drops `--redact` runs from the store
entirely — so there is no redacted stored copy to read, and sharing a past
run has to redact at read time. `--share=-` reads one run's JSON on stdin,
which is how netdiag.app shares the report already on screen without
re-running anything.
```

If Task 1 omitted the `--share` help lines, add them now under `Sharing and output:`.

- [ ] **Step 7: Run everything**

```bash
bats tests/test_share.bats tests/test_sanity.bats && \
  shellcheck -x bin/netdiag lib/*.sh && \
  ./bin/netdiag --share | head -25
```

Expected: all bats PASS, shellcheck silent, and a readable redacted report from your real store.

- [ ] **Step 8: Commit**

```bash
git add bin/netdiag CLAUDE.md tests/test_share.bats
git commit -m "feat: netdiag --share prints a report you can paste

Bare --share takes the newest stored run, --share=ID takes a
specific one, --share=- reads a run's JSON on stdin. The last is
what the app uses: it already holds the report on screen, so
sharing it re-runs nothing.

An empty store exits 3, not 2 — 2 is reserved for a real diagnosis
so a wrapper can tell 'you typed it wrong' from 'your network is
broken'."
```

## Task 16: Copy report in the app

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/NetdiagRunner.swift`
- Modify: `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
- Modify: `gui/Sources/NetdiagGUI/Views/ExpertPanel.swift`

- [ ] **Step 1: Give `execute` an optional stdin**

In `NetdiagRunner.swift`, change `execute`'s signature (line 214) to:

```swift
    static func execute(
        arguments: [String],
        stdin: String? = nil,
        stderrLines: AsyncStream<String>.Continuation? = nil
    ) async throws -> (String, String, Int32) {
```

Immediately after `process.standardError = errPipe` (line 227), add:

```swift
        // Feeding stdin needs its own pipe, and the write has to happen
        // off this thread *after* the process is running: a JSON body
        // larger than the pipe buffer (64 KB on macOS) blocks the writer
        // until the child drains it, and the child cannot drain while we
        // are blocked here not reading its stdout. Deadlock, on exactly
        // the large reports worth sharing.
        var inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            inPipe = pipe
            process.standardInput = pipe
        }
```

Then, immediately after the existing `try process.run()` call inside the continuation body, add:

```swift
                    if let inPipe, let stdin, let data = stdin.data(using: .utf8) {
                        DispatchQueue.global(qos: .userInitiated).async {
                            inPipe.fileHandleForWriting.write(data)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
```

> Find the exact `try process.run()` site before editing — it sits inside `withCheckedThrowingContinuation` alongside the `terminationHandler`. The write must come after it, or there is no child to read the pipe.

- [ ] **Step 2: Add the share call**

Add to `NetdiagRunner`, beside `history(limit:)` and `show(id:)`:

```swift
    /// `netdiag --share=-`, fed the run's own JSON on stdin.
    ///
    /// stdin rather than a run id so the report on screen shares exactly
    /// as it is — including one that finished two seconds ago and has not
    /// been looked up in the store yet. The redaction and the wording are
    /// entirely the CLI's; this returns its bytes untouched, per CLAUDE.md
    /// on where the app is allowed to have an opinion.
    static func share(rawJSON: String) async throws -> String {
        let (out, err, status) = try await execute(arguments: ["--share=-"],
                                                    stdin: rawJSON)
        guard status == 0 else {
            throw NetdiagError.scriptError(
                String((err.isEmpty ? out : err).prefix(400)))
        }
        return out
    }
```

- [ ] **Step 3: Add the button to the report card**

In `RunReportView.swift`, add to the type:

```swift
    @State private var shareError: String?
    @State private var didCopy = false
```

and change `body` to:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
            diagnoses
            copyRow
        }
    }

    /// Copies the CLI's own redacted rendering, never a re-encode of this
    /// app's partial model — the same reason `RunResult` keeps `rawJSON`
    /// around at all.
    @ViewBuilder
    private var copyRow: some View {
        HStack(spacing: 8) {
            Button(didCopy ? "Copied" : "Copy report") {
                copyShareableReport()
            }
            .controlSize(.small)
            .disabled(didCopy)
            Text("Plain text, with your network name, IP addresses and location masked.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let shareError {
                Text(shareError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func copyShareableReport() {
        guard let raw = rawJSON else {
            shareError = "This report came from an older netdiag and can't be shared."
            return
        }
        Task { @MainActor in
            do {
                let text = try await NetdiagRunner.share(rawJSON: raw)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                shareError = nil
                didCopy = true
                try? await Task.sleep(for: .seconds(2))
                didCopy = false
            } catch {
                shareError = "Couldn't build a shareable report."
            }
        }
    }
```

`RunReportView` currently receives only a `RunSnapshot`, not the raw bytes. Add a stored property beside `comparison`:

```swift
    /// The CLI's own bytes for this run, when the caller has them. `nil`
    /// for a snapshot decoded without them — the Copy control says so
    /// rather than silently vanishing.
    var rawJSON: String?
```

Then pass it at both call sites in `HomeView.swift`:

```swift
                case .live(let run):
                    RunReportView(snapshot: run.snapshot, rawJSON: run.rawJSON,
                                  showRuleIDs: appSettings.expertExpanded)
                case .stored(let detail):
                    RunReportView(snapshot: detail.run, comparison: detail.comparison,
                                  rawJSON: detail.asRunResult.rawJSON,
                                  showRuleIDs: appSettings.expertExpanded)
```

> Argument order must match the property declaration order in the struct — Swift memberwise initialisers are positional. Put `rawJSON` after `comparison` in the declaration and the calls above compile as written. Also add `import AppKit` at the top of `RunReportView.swift` for `NSPasteboard`, and check `RunDetailView.swift`, which constructs a `RunReportView` too — it needs the new argument or an explicit `nil`.

- [ ] **Step 4: Relabel the unsafe copy**

In `ExpertPanel.swift:246`, change:

```swift
                Button("Copy") {
```

to:

```swift
                // Named for what it does. This is the whole record with
                // the public IP, IPv6 address, SSID, BSSID, gateway MAC
                // and city in it — useful for a bug report, wrong for a
                // support chat. "Copy report" on the card above is the
                // redacted one, and the labels have to make that obvious
                // because the consequence of picking wrong is published.
                Button("Copy raw JSON (unredacted)") {
```

- [ ] **Step 5: Build and verify**

```bash
make -C gui build && make -C gui run
```

With the app running: press **Copy report** on Home, paste into a text editor, and confirm the text has no public IP, no SSID, no BSSID, no IPv6 address and no city — and that the ISP name and diagnosis prose survive. Then open Technical detail and confirm the raw-JSON button is now labelled "Copy raw JSON (unredacted)".

- [ ] **Step 6: Commit**

```bash
git add gui/Sources/NetdiagGUI/Services/NetdiagRunner.swift \
        gui/Sources/NetdiagGUI/Views/RunReportView.swift \
        gui/Sources/NetdiagGUI/Views/ExpertPanel.swift \
        gui/Sources/NetdiagGUI/Views/HomeView.swift \
        gui/Sources/NetdiagGUI/Views/RunDetailView.swift
git commit -m "feat(gui): Copy report puts a safe report on the clipboard

The app's only copy button emitted raw JSON carrying the machine's
public IPv4 and IPv6 addresses, SSID, BSSID, gateway MAC and city —
an IPv6 address identifies a household the way a NATed v4 address
does not. RunSnapshot.swift has named a 'Copy shareable report'
feature in a doc comment since before this; here it is.

Pipes the run's own bytes through netdiag --share=-, so the
redaction and every word of the text are the CLI's. The raw-JSON
button is now labelled unredacted: the consequence of picking the
wrong one is published, so the labels have to say which is which.

stdin is written off-thread after the child starts — a report
larger than the 64 KB pipe buffer would otherwise deadlock against
our own unread stdout."
```

## Task 17: Documentation and changelog

**Files:**
- Modify: `docs/JSON-SCHEMA.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Document `--share` in the schema reference**

In `docs/JSON-SCHEMA.md`, beside the `--show` section, add a `--share` section noting that it is the one mode emitting **text, not JSON**, that its input is a run record (stdin with `=-`, otherwise resolved from the store), and that its redaction mirrors `emit_json.py`'s `_REDACT_ENV` — reproducing the kept/masked table from the design spec.

- [ ] **Step 2: Update the README**

Add `--share` to the flag table, and move the two shipped roadmap items into "Shipped": the full check reachable from the app, and the shareable report.

- [ ] **Step 3: Write the changelog entry**

Add to `CHANGELOG.md` under `## [Unreleased]`, following the existing entries' style — the observed behaviour, the verified cause with file and line, and what changed. Cover all four items. State plainly that `--summary`'s 173-disconnect figure was an artefact of summed overlapping windows, and that `Depth.full` had no callers.

- [ ] **Step 4: Verify the changelog tests still pass**

```bash
bats tests/test_changelog.bats
```

Expected: PASS. That file enforces the changelog's structure — read it before writing if the entry is rejected.

- [ ] **Step 5: Full suite and final check**

```bash
bats tests/ 2>&1 | grep -c '^not ok'    # expect: 1 (the known NET.2 failure)
shellcheck -x bin/netdiag lib/*.sh
make -C gui build
swift run --package-path gui NetdiagGUI --verify
```

Expected: exactly 1 bats failure (`test_history.bats:116`), shellcheck silent, Swift build clean, `--verify` exits 0.

- [ ] **Step 6: Refresh the sample output**

`CLAUDE.md` requires `examples/sample-output.{txt,json}` be real captures. The report card is unchanged by this work, but a full check now produces rows the current sample lacks.

```bash
./bin/netdiag --redact --json > examples/sample-output.json
./bin/netdiag --redact | sed $'s/\x1b\\[[0-9;]*[mK]//g' > examples/sample-output.txt
```

> Capture from **stdout**, never via `--log` — the log deliberately keeps full detail, so a `--log` capture yields an unredacted file that looks like it worked. This repo is public.

Then confirm no identifying value survived:

```bash
grep -iE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f]{2}(:[0-9a-f]{2}){5}' examples/sample-output.txt
```

Expected: only RFC1918 addresses (`192.168.*`, `10.*`, `172.16-31.*`), which are kept by design. A public address or a MAC in that output is a leak — stop and fix before committing.

- [ ] **Step 7: Commit**

```bash
git add docs/JSON-SCHEMA.md README.md CHANGELOG.md examples/
git commit -m "docs: document --share and record the reachable-features work

Refreshes the samples from a real run, captured with --redact from
stdout — a --log capture keeps full detail by design and would
publish this machine's addresses to a public repo."
```

---

## Self-review notes

**Spec coverage.** Every section of the design maps to a task: §1 full check → Tasks 2-8; §2 `--share` → Tasks 13-16; §3 `--summary` → Tasks 9-12; §4 `--help` → Task 1; testing → folded into each task plus Task 17's full-suite gate; the `NET.2` routing decision → Task 11's step 3 note and its commit message.

**Verified against the live tool on 2026-08-25, not assumed:** `--history`'s
run rows (flat `doc["runs"]`, keyed `id`/`ts`), `--show`'s wrapper
(`doc["run"]` is the whole record), `helpers/history.py` importing cleanly
with no side effects and exposing `group_key`/`clean`/`is_redacted`, the
Python version (3.9.6), `Depth.full` having zero call sites, `--quick`
skipping the MTU probe, `WIFI_DISCONNECT_WINDOW_HOURS=1`, every threshold
name used in Task 12 existing in `lib/thresholds.sh`, and the current bats
baseline (1 known failure).

**One thing a reader should check rather than trust:** Task 11's third test
relies on a later `network` object overriding an earlier one in the same JSON
text. Python's `json.loads` accepts this and keeps the last, but if you
restructure the `rec` helper, the assertion is what matters, not the
mechanism.

**Naming consistency across tasks:** `FullCheckPolicy.isSafe(severity:)` (Task 2) is called by `coordinator.fullCheckIsSafe` (Task 3), read by `HomeView.fullCheckHelp` (Task 4). `plural(_:_:)` is introduced in Task 9 and used in Tasks 10, 11 and 12. `NetdiagRunner.share(rawJSON:)` is introduced in Task 16 step 2 and called in step 3. `render(_:)` is stubbed in Task 13 and replaced in Task 14.

**Ordering constraint:** Tasks 4, 5 and 16 all edit view files that Task 3 must land before (they call `runFullCheck`). Tasks 9-12 are strictly sequential — each builds on the previous one's structure of `summary.py`. Task 1 and Tasks 9-12 are independent of the Swift work and can proceed in parallel with it if two people are working.
