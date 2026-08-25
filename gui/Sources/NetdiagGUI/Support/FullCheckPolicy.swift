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
