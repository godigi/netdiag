import Foundation

/// The dropdown's stage card, decided by a pure function.
///
/// Extracted from `DropdownView.stage` so the mapping is testable without
/// constructing a coordinator: the reactivity guarantee it encodes (the
/// card reflects the CLI's current verdict the moment a rule fires, not
/// 15–25 s later when the alert's dwell elapses) is the one thing most
/// worth a repeatable check, and a computed property on a View that reads
/// a dozen `@Environment` objects cannot be checked. The in-app
/// `--verify` mode (see `VerifyMode.swift`) calls `resolve` directly with
/// constructed inputs and asserts every severity → stage mapping.
///
/// The GUI-holds-no-diagnostic-logic rule is preserved: nothing here
/// decides whether a number is bad. `severity` arrives pre-computed from
/// `lib/monitor.sh`'s `_mon_rules`; this only maps "what severity did the
/// CLI report" to "which card shows".
enum StageResolver {

    /// The one card the dropdown leads with.
    enum Stage: Equatable, Sendable {
        case skewed(String)
        case testing
        case paused(String?)
        case alerted(AlertSnapshot)
        /// The CLI sees a problem but no alert has crossed its dwell yet.
        /// `critical` reads red, `warn` reads amber; the card carries the
        /// CLI's own blurb for the worst firing rule (the same source
        /// `NetdiagCoordinator.headline` uses), never a verdict authored
        /// here. This is the state that used to be silently `.healthy`
        /// for up to 15–25 s while the timeline below already showed the
        /// drop — the green-card-over-red-timeline gap the dropdown was
        /// rebuilt to close.
        case watching(severity: WatchingSeverity)
        case healthy
    }

    enum WatchingSeverity: String, Sendable { case warn, critical }

    /// A snapshot of the one active alert the stage renders when the dwell
    /// has elapsed. Decoupled from `AlertEngine.ActiveAlert` so the resolver
    /// and the verify harness depend on nothing but Foundation.
    struct AlertSnapshot: Equatable, Sendable {
        let title: String
        let body: String
        let raisedAt: Date
        let rules: Set<String>
        init(title: String, body: String, raisedAt: Date, rules: Set<String>) {
            self.title = title; self.body = body
            self.raisedAt = raisedAt; self.rules = rules
        }
    }

    /// Everything `resolve` needs, as plain values. Built at the call site
    /// from the coordinator's observable state.
    struct Inputs: Sendable {
        let isScanning: Bool
        let monitoringEnabled: Bool
        let isPausedForAnyReason: Bool
        let pauseReason: String?
        let lastError: String?
        let monitorRunning: Bool
        let activeAlert: AlertSnapshot?
        /// "ok" | "info" | "warn" | "critical" from the latest sample's
        /// `status.severity`. "info" (VPN on, ICMP filtered) is not a
        /// problem and reads healthy.
        let severity: String
        let linkUp: Bool
        init(isScanning: Bool, monitoringEnabled: Bool,
             isPausedForAnyReason: Bool, pauseReason: String?,
             lastError: String?, monitorRunning: Bool,
             activeAlert: AlertSnapshot?, severity: String, linkUp: Bool) {
            self.isScanning = isScanning
            self.monitoringEnabled = monitoringEnabled
            self.isPausedForAnyReason = isPausedForAnyReason
            self.pauseReason = pauseReason
            self.lastError = lastError
            self.monitorRunning = monitorRunning
            self.activeAlert = activeAlert
            self.severity = severity
            self.linkUp = linkUp
        }
    }

    /// The order of the guards is load-bearing and matches the precedence
    /// the dropdown has always had: a scan in progress, then a user pause,
    /// then a skewed CLI, then an already-active alert. Only after all four
    /// fall through does severity decide between `.watching` and `.healthy`
    /// — the step that closes the green-card-over-red-timeline gap.
    static func resolve(_ i: Inputs) -> Stage {
        if i.isScanning { return .testing }
        if !i.monitoringEnabled { return .paused(nil) }
        if i.isPausedForAnyReason { return .paused(i.pauseReason) }
        if let error = i.lastError, !i.monitorRunning { return .skewed(error) }
        if let alert = i.activeAlert { return .alerted(alert) }
        if !i.linkUp { return .watching(severity: .critical) }
        switch i.severity {
        case "critical": return .watching(severity: .critical)
        case "warn":     return .watching(severity: .warn)
        default:         return .healthy
        }
    }
}
