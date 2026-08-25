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

    /// The label and tooltip for a full-check control, given whether a
    /// full check is currently safe. Here rather than in either view so
    /// Home and the dropdown can never describe the same button two
    /// different ways — the same reason `SignalScale.cellContent` is
    /// shared between them.
    ///
    /// Mechanism only, never a verdict about the network: this file is
    /// allowed to say what netdiag will *do*, and nothing about what is
    /// wrong. See AlertDefinitions.swift's header for the contract.
    static func controlLabel(isSafe: Bool) -> String {
        isSafe
            ? "Full check · \(NetdiagRunner.Depth.full.estimate)"
            : "Lighter check · \(NetdiagRunner.Depth.alertTriggered.estimate)"
    }

    /// What the check measures, and — in the fallback state — which
    /// measurements are being left out and why.
    ///
    /// Mechanism only. An earlier version of this string opened by
    /// asserting, flatly, that the connection was down at that very
    /// instant — a verdict authored in Swift (forbidden — see
    /// AlertDefinitions.swift's header) and untrue besides: `isSafe` also
    /// reads false on an empty severity, which is what a fresh launch has
    /// before the first monitor sample lands. "The last reading wasn't
    /// clearly healthy" is true in all three declining cases — critical,
    /// unknown, and not-yet-measured — and states what the app knows
    /// rather than what it guesses.
    static func controlHelp(isSafe: Bool) -> String {
        isSafe
            ? "Adds speed, latency under load, path MTU and per-hop loss to the report."
            : "The last reading wasn't clearly healthy, so this runs a lighter check — no load test and no speed test — rather than adding traffic to a link that may already be struggling."
    }
}
