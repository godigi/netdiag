import Foundation
import UserNotifications
import os

/// Decides *whether and when* to notify. It never decides what is wrong.
///
/// The split is the whole architecture: lib/monitor.sh and lib/diagnosis.sh
/// say which rules fired, this file says which of those are worth
/// interrupting someone over. Nothing here reads a measurement or compares
/// it to a number.
///
/// Each alert runs a small state machine:
///
///   idle ──condition holds for `dwell`──▶ firing ──notify──▶ active
///     ▲                                                        │
///     └──────────── condition absent, `resolves` ◀─────────────┘
///
/// plus a `cooldown` that suppresses a repeat notification of an alert that
/// is already known, and four global suppressors that hold everything.
@MainActor
@Observable
final class AlertEngine {

    /// One alert currently raised, for the dropdown's banner.
    struct ActiveAlert: Identifiable, Sendable {
        let id: String
        let title: String
        var body: String
        var raisedAt: Date
        /// Set once a triggered scan lands and replaces the holding text
        /// with the CLI's own prose.
        var enrichedByScan: Bool = false
        /// The rule IDs from `AlertDefinition.rules` that back this alert —
        /// empty for the four event-driven alerts (VPN dropped, public IP
        /// changed, ...) that have no rule at all. Carried here rather than
        /// looked up again at render time so the dropdown's attribution
        /// line and `activeSorted`'s ranking read the exact set that fired.
        var rules: Set<String> = []
    }

    private(set) var active: [String: ActiveAlert] = [:]
    private(set) var notificationsAuthorized = false

    /// Set by the app when a scan starts, so alerts are held rather than
    /// fired against measurements the app's own traffic is distorting.
    var scanInProgress = false
    /// Set from the display-sleep / battery / user-toggle paths.
    var monitoringPaused = false
    /// Supplied by NetworkEventWatcher: true for 30 s after any network
    /// transition.
    var inNetworkGracePeriod: () -> Bool = { false }
    /// Injected by `NetdiagCoordinator` once the rules catalog has a
    /// version to answer from: rule ID in, the catalog's severity rank out
    /// (higher is worse). Default ranks everything 0 — before the catalog
    /// loads, `activeSorted` degrades to raised-time order rather than
    /// pretending to know which alert is worse.
    @ObservationIgnored var severityRank: (String) -> Int = { _ in 0 }

    /// Raised when an alert fires and the user has auto-scan on. The app
    /// wires this to NetdiagRunner; the loop guard lives there.
    var onAlertFired: ((AlertDefinition) -> Void)?

    private var conditionSince: [String: Date] = [:]
    private var lastNotifiedAt: [String: Date] = [:]
    private var firedForNetwork: [String: Set<String>] = [:]
    private var previousSample: MonitorSample?
    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "alerts")

    // MARK: - Permission

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            notificationsAuthorized = try await center.requestAuthorization(
                options: [.alert, .sound])
        } catch {
            // Requesting from a process with no bundle identity throws.
            // That is a build problem (running .build/release/NetdiagGUI
            // instead of the assembled .app), not something the user did.
            log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            notificationsAuthorized = false
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    // MARK: - Global suppressors
    //
    // Each of these prevents a distinct class of false alarm, and each was
    // chosen because the alternative is an alert that is *always* wrong
    // rather than occasionally wrong.

    private func suppressed(_ def: AlertDefinition, sample: MonitorSample?) -> String? {
        if !Defaults.isAlertEnabled(def.id) { return "disabled by user" }
        // A scan saturates the link on purpose (speed test, bufferbloat).
        // Alerting on latency the app itself caused is the worst possible
        // false positive: it is self-inflicted and perfectly reproducible.
        if scanInProgress { return "a check is running" }
        if monitoringPaused { return "monitoring paused" }
        // DHCP, DNS and the default route land a beat apart after a switch.
        // Probes in the first seconds measure a half-configured stack.
        if inNetworkGracePeriod() { return "network just changed" }
        // TCP-1: real connections work, only ping is being dropped. Hotel
        // and corporate networks block ICMP wholesale, and without this a
        // loss alert there fires constantly and is never once correct.
        if def.suppressedByICMPFilter, sample?.status.icmpFiltered == true {
            return "ICMP filtered (TCP-1)"
        }
        return nil
    }

    // MARK: - Live evaluation

    func evaluate(sample: MonitorSample) {
        defer { previousSample = sample }
        let now = Date()
        let networkKey = sample.network.id ?? "unknown"

        for def in AlertDefinition.liveAlerts {
            let holds = conditionHolds(def, sample: sample, previous: previousSample)
            step(def, holds: holds, now: now, networkKey: networkKey, sample: sample)
        }
    }

    /// Which live alerts a sample raises. Rule-driven where a rule exists;
    /// the four event-driven ones read a transition instead, because "your
    /// VPN dropped" is a change rather than a state and no rule can say it.
    private func conditionHolds(_ def: AlertDefinition,
                                sample: MonitorSample,
                                previous: MonitorSample?) -> Bool {
        switch def.id {
        case "public-ip-changed":
            guard let prev = previous,
                  let old = prev.publicInfo.ip, let new = sample.publicInfo.ip,
                  !old.isEmpty, !new.isEmpty else { return false }
            return old != new

        case "captive-portal":
            return sample.publicInfo.captivePortal == true

        case "vpn-dropped":
            guard let prev = previous else { return false }
            return prev.vpn.active && !sample.vpn.active

        case "different-network":
            // Same Wi-Fi name, different router behind it. Only meaningful
            // when the SSID is actually visible — without Location
            // Services macOS hides it, and comparing two nils would fire
            // this on every gateway the machine ever sees.
            guard let prev = previous,
                  let prevSSID = prev.link.ssid, let ssid = sample.link.ssid,
                  !prevSSID.isEmpty, prevSSID == ssid,
                  let prevMAC = prev.link.gatewayMAC, let mac = sample.link.gatewayMAC,
                  !prevMAC.isEmpty else { return false }
            return prevMAC != mac

        default:
            return !def.rules.isDisjoint(with: Set(sample.status.rules))
        }
    }

    // MARK: - Scan evaluation

    /// Scan-only alerts, plus the enrichment pass that replaces a live
    /// alert's holding text with the CLI's own prose.
    func evaluate(run: RunSnapshot) {
        let now = Date()
        let networkKey = run.network.id ?? "unknown"
        let firedRules = Set(run.diagnosis.compactMap(\.rule))

        for def in AlertDefinition.scanAlerts {
            step(def, holds: !def.rules.isDisjoint(with: firedRules),
                 now: now, networkKey: networkKey, sample: nil,
                 bodyOverride: bestSummary(for: def, in: run))
        }

        // The point of the alert-triggered scan: "Connection is unstable"
        // becomes "You're losing packets between your Mac and your router
        // even though the WiFi signal is strong — the router itself is
        // misbehaving. Try rebooting it (unplug for 30 seconds, plug back
        // in)." The notification updates in place rather than arriving a
        // second time.
        for (id, var alert) in active where !alert.enrichedByScan {
            guard let def = AlertDefinition.byID(id),
                  let summary = bestSummary(for: def, in: run) else { continue }
            alert.body = summary
            alert.enrichedByScan = true
            active[id] = alert
            deliver(id: id, title: alert.title, body: summary, replacing: true)
        }
    }

    /// The CLI's own sentence for this alert: the highest-severity
    /// diagnosis whose rule the alert listens for. Verbatim, never edited.
    private func bestSummary(for def: AlertDefinition, in run: RunSnapshot) -> String? {
        let matching = run.diagnosis.filter { d in
            guard let rule = d.rule else { return false }
            return def.rules.contains(rule)
        }
        for severity in ["critical", "warn", "info"] {
            if let hit = matching.first(where: { $0.severity == severity }) { return hit.summary }
        }
        return nil
    }

    // MARK: - The state machine

    private func step(_ def: AlertDefinition, holds: Bool, now: Date,
                      networkKey: String, sample: MonitorSample?,
                      bodyOverride: String? = nil) {
        guard holds else {
            conditionSince.removeValue(forKey: def.id)
            if def.resolves, let alert = active.removeValue(forKey: def.id) {
                // Only announce a recovery for something we announced
                // breaking. Silently clearing would leave the user
                // wondering whether it is still wrong.
                deliverResolved(id: def.id, title: alert.title)
            } else {
                active.removeValue(forKey: def.id)
            }
            return
        }

        if let reason = suppressed(def, sample: sample) {
            // Reset the dwell clock. A condition that held only while
            // suppressed has not held in the sense the dwell measures.
            conditionSince.removeValue(forKey: def.id)
            log.debug("\(def.id, privacy: .public) suppressed: \(reason, privacy: .public)")
            return
        }

        let since = conditionSince[def.id] ?? now
        conditionSince[def.id] = since
        guard now.timeIntervalSince(since) >= def.dwell else { return }
        guard active[def.id] == nil else { return }

        if def.oncePerNetwork {
            if firedForNetwork[networkKey, default: []].contains(def.id) { return }
            firedForNetwork[networkKey, default: []].insert(def.id)
        } else if let last = lastNotifiedAt[def.id],
                  now.timeIntervalSince(last) < def.cooldown {
            // Still inside the cooldown: track it as active so the
            // dropdown shows it, but do not interrupt again.
            active[def.id] = ActiveAlert(id: def.id, title: def.title,
                                         body: bodyOverride ?? def.interimBody, raisedAt: now,
                                         rules: def.rules)
            return
        }

        let body = bodyOverride ?? def.interimBody
        active[def.id] = ActiveAlert(id: def.id, title: def.title, body: body,
                                     raisedAt: now, enrichedByScan: bodyOverride != nil,
                                     rules: def.rules)
        lastNotifiedAt[def.id] = now
        deliver(id: def.id, title: def.title, body: body, replacing: false)
        log.info("alert fired: \(def.id, privacy: .public)")

        // Only live alerts trigger a scan. A scan-only alert was produced
        // *by* a scan, and scanning again to explain it is the loop the
        // guard in NetdiagCoordinator exists to prevent.
        if !def.scanOnly { onAlertFired?(def) }
    }

    // MARK: - Delivery

    private func deliver(id: String, title: String, body: String, replacing: Bool) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = replacing ? nil : .default

        // Same identifier for the fire and the enrichment, so the second
        // one updates the banner in place instead of stacking a duplicate
        // in Notification Center.
        let request = UNNotificationRequest(identifier: "netdiag.\(id)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func deliverResolved(id: String, title: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(title) — resolved"
        content.sound = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "netdiag.\(id).resolved",
                                  content: content, trigger: nil))
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["netdiag.\(id)"])
    }

    // MARK: - Housekeeping

    /// Clear the once-per-network memory for a network we have left, so
    /// rejoining a captive-portal network next week prompts again. Keyed on
    /// the network we are *on* rather than a timer, because "once per
    /// network" means exactly that.
    func networkChanged(to id: String?) {
        guard let id else { return }
        for key in firedForNetwork.keys where key != id {
            firedForNetwork.removeValue(forKey: key)
        }
    }

    /// Worst first, so the dropdown's one-alert stage always shows the
    /// alert most worth interrupting someone over rather than whichever
    /// happened to fire most recently. Rank comes from the CLI's own
    /// severity by way of `severityRank`, never a judgment made here; ties
    /// (including the pre-catalog default rank of 0 for everything) fall
    /// back to newest first.
    var activeSorted: [ActiveAlert] {
        active.values.sorted { a, b in
            let rankA = a.rules.compactMap(severityRank).max() ?? 0
            let rankB = b.rules.compactMap(severityRank).max() ?? 0
            if rankA != rankB { return rankA > rankB }
            return a.raisedAt > b.raisedAt
        }
    }
}
