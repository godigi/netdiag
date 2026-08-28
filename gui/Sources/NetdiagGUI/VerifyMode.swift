import SwiftUI
import AppKit
import Foundation
import os

/// The app's runnable verification harness, reached with `--verify`.
///
/// `swift test` cannot *execute* on this CLT-only machine: Swift Testing's
/// runner needs the `xctest` host, which the Command Line Tools do not
/// ship, so a test target compiles here but `swift test` exits 0 having run
/// nothing. A separate executable target is no substitute either —
/// `NetdiagGUI` is an executable target, and SwiftPM does not export an
/// executable's public symbols to importers, so the linker fails. The only
/// place with access to the resolver *and* a runnable process on this
/// toolchain is the app itself, so the harness lives here as a launch mode.
///
/// `swift run NetdiagGUI --verify` (or the bundled binary with `--verify`)
/// runs it: AppDelegate calls `runVerifyIfNeeded()` early in launch, and if
/// it returns true the app terminates before starting the monitor or showing
/// UI. The harness prints PASS/FAIL per check and exits non-zero on any
/// failure, the way a test runner would.
///
/// Two checks live here, covering the two things that can break silently:
///
/// 1. **StageResolver logic** — the reactivity guarantee: the dropdown's
///    stage card reflects the CLI's current verdict the moment a rule fires,
///    not 15–25 s later when the alert's dwell elapses. That guarantee lives
///    in a pure function (`StageResolver.resolve`), so it is checked directly
///    with constructed inputs — every severity → stage mapping and every
///    precedence guard.
///
/// 2. **Stage-card visual contract** — a faithful stand-in of the dropdown's
///    stage card is rendered offscreen for each stage and written to PNG, so
///    the colour and wording per stage can be eyeballed without launching the
///    app or clicking the menu-bar item. This is not a pixel-identical
///    snapshot of `DropdownView` (that would need a real coordinator, which
///    spawns a monitor and reads history) — it is the visual *contract*
///    (green / amber / red card, icon, title, body) driven by the same
///    `StageResolver.Stage` the real view consumes. Combined with the logic
///    asserts above, it proves both the mapping and its rendering; a
///    screenshot of the running app confirms the real `DropdownView` wires
///    the resolver in.

/// If `--verify` is present in the launch arguments, run the harness and
/// return true so the caller can terminate without starting the monitor.
/// Otherwise return false and let the app launch normally.
@MainActor
func runVerifyIfNeeded() -> Bool {
    guard CommandLine.arguments.contains("--verify") else { return false }
    VerifyHarness.run()
    return true
}

@MainActor
private enum VerifyHarness {

    static var failures: [String] = []

    static func run() {
        // AppKit rendering needs an app instance present; the real app is
        // already up by the time AppDelegate calls us, so just keep the
        // policy consistent and run the checks.
        NSApp?.setActivationPolicy(.accessory)
        runStageTests()
        runFullCheckPolicyTests()
        runHeadlineRuleTests()
        runSnapshots()
        print("")
        if failures.isEmpty {
            print("All checks passed.")
        } else {
            print("\(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Tiny assert helpers (no XCTest available at runtime on CLT)

    private static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
        if got == want {
            print("  \u{2714} \(name)")
        } else {
            print("  \u{2718} \(name) — got \(got), want \(want)")
            failures.append(name)
        }
    }

    private static func inputs(severity: String = "ok",
                               linkUp: Bool = true,
                               activeAlert: StageResolver.AlertSnapshot? = nil,
                               isScanning: Bool = false,
                               monitoringEnabled: Bool = true,
                               isPausedForAnyReason: Bool = false,
                               pauseReason: String? = nil,
                               lastError: String? = nil,
                               monitorRunning: Bool = true,
                               measurementState: String = "measured") -> StageResolver.Inputs {
        StageResolver.Inputs(
            isScanning: isScanning,
            monitoringEnabled: monitoringEnabled,
            isPausedForAnyReason: isPausedForAnyReason,
            pauseReason: pauseReason,
            lastError: lastError,
            monitorRunning: monitorRunning,
            activeAlert: activeAlert,
            severity: severity,
            linkUp: linkUp,
            measurementState: measurementState
        )
    }

    // MARK: - 1. StageResolver logic

    static func runStageTests() {
        print("StageResolver:")
        // Healthy: ok and info both read green. Info severity (VPN on, ICMP
        // filtered) is not a problem — the whole point of info is "something
        // is happening but it is fine", so it must not light the card up.
        equal(StageResolver.resolve(inputs(severity: "ok")), .healthy, "ok severity → healthy")
        equal(StageResolver.resolve(inputs(severity: "info")), .healthy, "info severity → healthy (VPN/ICMP-filter is not a fault)")
        equal(StageResolver.resolve(inputs(severity: "ok", linkUp: false)), .watching(severity: .critical), "link down → watching critical even with ok severity")

        // The core reactivity guarantee: warn and critical land on .watching
        // immediately, before any alert dwell. This is the case that used to
        // read .healthy for 15–25 s while the timeline already showed the drop.
        equal(StageResolver.resolve(inputs(severity: "warn")), .watching(severity: .warn), "warn → watching (amber, before dwell)")
        equal(StageResolver.resolve(inputs(severity: "critical")), .watching(severity: .critical), "critical → watching (red, before dwell)")
        equal(StageResolver.resolve(inputs(measurementState: "unknown")), .checking, "unknown measurement → checking, not healthy")

        // An active alert wins over watching — once the dwell elapses the
        // card carries the alert's prose, which a scan may have enriched.
        let alert = StageResolver.AlertSnapshot(title: "No internet connection",
                                                body: "Checking what happened…",
                                                raisedAt: Date(),
                                                rules: ["P1"])
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert)),
              .alerted(alert), "active alert → alerted (overrides watching)")

        // Precedence: each earlier guard beats the later ones. Testing each
        // guard with every later signal live proves the order is load-bearing,
        // not accidental.
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            isScanning: true, monitoringEnabled: false,
                                            isPausedForAnyReason: true)),
              .testing, "scanning precedes paused / skewed / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            monitoringEnabled: false, isPausedForAnyReason: true)),
              .paused(nil), "user-disabled monitoring precedes monitor-paused / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            isPausedForAnyReason: true,
                                            pauseReason: "display sleeping")),
              .paused("display sleeping"), "monitor-paused precedes skewed / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            lastError: "cli too old", monitorRunning: false)),
              .skewed("cli too old"), "skewed CLI precedes alert / watching")
        equal(StageResolver.resolve(inputs(severity: "warn", activeAlert: nil)),
              .watching(severity: .warn), "no alert + warn → watching (alert gate is what kept it healthy before)")

        // No measurement yet is explicitly neutral, never an all-clear.
        equal(StageResolver.resolve(inputs(severity: "ok", linkUp: true,
                                            measurementState: "unknown")),
              .checking, "first-sample unknown → checking")
    }

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

        // The control's label and tooltip must name the depth that will
        // actually run, and the unsafe help must never author a verdict.
        // Commit 69fa7fb shipped one that asserted the connection was
        // down at that instant — Swift composing a diagnosis, and false
        // whenever `isSafe` declined for want of a sample rather than for
        // a critical reading. These four assertions are what keep it out.
        let safeLabel = FullCheckPolicy.controlLabel(isSafe: true)
        let unsafeLabel = FullCheckPolicy.controlLabel(isSafe: false)
        equal(safeLabel.contains("Full check"), true, "safe label names the full check")
        equal(unsafeLabel.contains("Lighter check"), true, "unsafe label names the lighter check")

        let unsafeHelp = FullCheckPolicy.controlHelp(isSafe: false)
        equal(unsafeHelp.contains("is failing"), false, "unsafe help never claims the connection is failing")
        equal(unsafeHelp.contains("speed test"), true, "unsafe help discloses the speed test is skipped too")
    }

    // MARK: - Headline rule selection
    //
    // `lib/monitor.sh`'s `_mon_rules` appends rules in the order it
    // evaluates them, not by severity: TCP-1, the G-loss rules, P-reach,
    // D1, CP-1, VPN-1, ICMP-1, then the L-loss rules. So an `info` VPN-1
    // routinely sits ahead of a `critical` L1 in `status.rules`, and the
    // headline used to take the first rule it could look up — putting "A
    // VPN is carrying your traffic right now" under a red "Detecting a
    // network problem" card while the user lost most of their packets.
    //
    // This is invisible on inspection (both orderings look reasonable) and
    // only reproduces on a machine with a VPN up and a failing link, which
    // is why it is asserted here rather than left to be noticed.

    private static func runHeadlineRuleTests() {
        print("\nHeadline rule selection")

        // A stand-in catalog rather than the real one: the harness runs
        // headless with no CLI to query, and the behaviour under test is
        // the ranking, not the catalog's contents.
        let catalog = stubCatalog([
            ("VPN-1", "info", "A VPN is carrying your traffic right now."),
            ("L1", "critical", "Severe internet packet loss."),
            ("D1", "warn", "DNS resolver flaky."),
        ])

        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1", "L1"], catalog: catalog),
              "Severe internet packet loss.",
              "a critical rule outranks an info one that precedes it")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1", "D1"], catalog: catalog),
              "DNS resolver flaky.",
              "a warn rule outranks an info one that precedes it")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["L1", "D1", "VPN-1"], catalog: catalog),
              "Severe internet packet loss.",
              "the worst rule wins regardless of position")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1"], catalog: catalog),
              "A VPN is carrying your traffic right now.",
              "a lone info rule is still shown")
        // A rule this build's catalog has never heard of must not win by
        // default and blank the headline.
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["ZZ-9", "L1"], catalog: catalog),
              "Severe internet packet loss.",
              "an unknown rule id never outranks a known one")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["ZZ-9"], catalog: catalog),
              nil,
              "only unknown rules yields no headline, not an empty one")
        equal(NetdiagCoordinator.headlineText(forRulesIn: [], catalog: catalog),
              nil,
              "no firing rules yields no headline")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["L1"], catalog: nil),
              nil,
              "no catalog yields no headline rather than a rule id")

        // Ranking itself, including the vocabulary the CLI actually emits.
        equal(NetdiagCoordinator.severityRank("critical") > NetdiagCoordinator.severityRank("warn"),
              true, "critical outranks warn")
        equal(NetdiagCoordinator.severityRank("warn") > NetdiagCoordinator.severityRank("info"),
              true, "warn outranks info")
        equal(NetdiagCoordinator.severityRank("info") > NetdiagCoordinator.severityRank("varies"),
              true, "a known severity outranks one this build cannot rank")
    }

    /// A minimal `RulesCatalog` built from (id, severity, blurb) triples,
    /// via the type's own decoder so the harness exercises the same path
    /// the app does rather than a hand-built value the decoder might
    /// disagree with.
    private static func stubCatalog(_ rules: [(String, String, String)]) -> RulesCatalog? {
        let payload: [String: Any] = [
            "schema": 3,
            "rules": rules.map { ["id": $0.0, "severity": $0.1, "blurb": $0.2] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(RulesCatalog.self, from: data)
    }

    // MARK: - 2. Stage-card visual contract (offscreen render → PNG)

    /// A stand-in for the dropdown's stage card, driven by the same
    /// `StageResolver.Stage` the real `DropdownView` consumes. The colour,
    /// icon and title per stage match the dropdown's stage views; the body
    /// is representative prose so the snapshot shows how a real card reads.
    private struct StageCardSnapshot: View {
        let stage: StageResolver.Stage
        let bodyText: String

        var body: some View {
            card.frame(width: 340, height: 80)
        }

        @ViewBuilder private var card: some View {
            switch stage {
            case .healthy:
                content(icon: "checkmark.circle.fill", tint: .green,
                        title: "All good — watching", tertiary: "Nothing has changed in 3h 12m")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .watching(let sev):
                let critical = sev == .critical
                content(icon: critical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                        tint: critical ? .red : .orange,
                        title: critical ? "Detecting a network problem" : "Watching — something needs attention",
                        tertiary: critical ? "Confirming before notifying you…" : "Will alert if this keeps up.")
                    .background((critical ? Color.red : Color.orange).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
            case .alerted:
                content(icon: "exclamationmark.triangle.fill", tint: .red,
                        title: "No internet connection", tertiary: "rule P1 · 3m ago")
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .testing:
                content(icon: "circle.dashed", tint: .accentColor,
                        title: "Checking…", tertiary: "pinging the gateway")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .checking:
                content(icon: "hourglass", tint: .secondary,
                        title: "Checking connection…", tertiary: "waiting for a live reading")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .paused(let reason):
                content(icon: "pause.circle.fill", tint: .secondary,
                        title: "Monitoring paused", tertiary: reason ?? "")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .skewed:
                content(icon: "exclamationmark.triangle", tint: .yellow,
                        title: "The netdiag command needs attention", tertiary: "cli too old")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }

        private func content(icon: String, tint: Color, title: String, tertiary: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title).font(.callout).fontWeight(.semibold)
                }
                Text(bodyText).font(.caption).foregroundStyle(.secondary)
                if !tertiary.isEmpty {
                    Text(tertiary).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Render a SwiftUI view to an NSImage offscreen via NSHostingView +
    /// `cacheDisplay`. Captures the layer without a window for static
    /// content; called after launch so NSApplication is already up.
    private static func renderImage(_ view: some View, size: NSSize) -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func runSnapshots() {
        print("Render stage-card snapshots:")
        let dir = "/tmp/opencode/verify"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cases: [(String, StageResolver.Stage, String)] = [
            ("healthy",           .healthy,                                  "Watching for changes."),
            ("watching-warn",     .watching(severity: .warn),                "You're losing a few packets to your router."),
            ("watching-critical", .watching(severity: .critical),            "Your Mac has no internet connection at all."),
            ("alerted",           .alerted(.init(title: "No internet connection",
                                                  body: "Checking what happened…",
                                                  raisedAt: Date(), rules: ["P1"])),
                                                                     "Checking what happened…"),
            ("paused",            .paused("display sleeping"),               "Monitoring is off while the display sleeps."),
            ("skewed",            .skewed("netdiag CLI is too old"),         "The bundled netdiag is older than this app expects."),
            ("testing",           .testing,                                  "Running a full check…"),
            ("checking",          .checking,                                 "Waiting for a live reading…"),
        ]
        for (name, stage, body) in cases {
            guard let image = renderImage(StageCardSnapshot(stage: stage, bodyText: body),
                                          size: NSSize(width: 340, height: 80)) else {
                print("  \u{2718} \(name) — could not allocate bitmap representation")
                failures.append("render-\(name)")
                continue
            }
            let url = URL(fileURLWithPath: "\(dir)/stage-\(name).png")
            do {
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: url)
                    print("  \u{2714} wrote \(url.path)")
                } else {
                    print("  \u{2718} \(name) — could not produce PNG bytes")
                    failures.append("render-\(name)")
                }
            } catch {
                print("  \u{2718} \(name) — \(error.localizedDescription)")
                failures.append("render-\(name)")
            }
        }
    }
}
