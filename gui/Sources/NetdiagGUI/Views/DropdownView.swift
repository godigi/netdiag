import SwiftUI
import AppKit
import CoreWLAN

/// Layer two of four: the dropdown status menu.
///
/// One swappable "stage" over a fixed instrument grid:
/// 1. Stage — a single card whose content is a function of app state
///    (healthy / alerted / testing / paused / skewed). Everything below it
///    never moves.
/// 2. One primary CTA: Check My Connection, directly under the stage.
/// 3. Heartbeat strip — a thin live sparkline of internet ping, labeled
///    with min/avg/max, directly under the CTA, proving monitoring is alive.
/// 4. Instrument grid — fixed 4x2: internet ping, internet loss, download,
///    upload / router, Wi-Fi, VPN, location. Cells never disappear; an
///    unmeasured value renders as "—".
/// 5. Change timeline — "LAST 24 HOURS" header, a "History" button into
///    the dashboard's Activity view, and the most recent events, sourced
///    from `coordinator.eventLog`.
/// 6. Footer: Open Dashboard, Pause/Resume Monitoring, Settings, Quit,
///    version.
struct DropdownView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow
    /// The Wi-Fi cell's CoreWLAN fallback, cached rather than read inside
    /// `wifiCell` — see `resolvedRSSI`'s header. Refreshed by the `.task`
    /// below, at most once per incoming monitor sample.
    @State private var coreWLANRSSI: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stageSection
                .padding(.horizontal, Theme.Spacing.md)

            checkButton
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            heartbeatSection
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            instrumentSection
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)

            Divider().padding(.vertical, Theme.Spacing.xs)

            timelineSection
                .padding(.horizontal, Theme.Spacing.md)

            Divider().padding(.vertical, Theme.Spacing.xs)

            controlsSection
        }
        .padding(.vertical, Theme.Spacing.sm)
        .task {
            if coordinator.history.document.runs.isEmpty {
                await coordinator.history.load()
            }
        }
        // A live CoreWLAN read on every render would make the Wi-Fi cell
        // cost a syscall per redraw of an always-visible menu; keying the
        // task on the sample sequence number throttles it to once per
        // incoming sample instead — the fast tier's own cadence (10 s,
        // 5 s degraded) is throttle enough.
        .task(id: coordinator.monitor.latest?.seq) {
            refreshCoreWLANRSSIIfNeeded()
        }
    }

    // MARK: - Stage

    private var stage: StageResolver.Stage {
        StageResolver.resolve(.init(
            isScanning: coordinator.isScanning,
            monitoringEnabled: appSettings.monitoringEnabled,
            isPausedForAnyReason: coordinator.monitor.isPausedForAnyReason,
            pauseReason: coordinator.monitor.pauseReason,
            lastError: coordinator.monitor.lastError,
            monitorRunning: coordinator.monitor.isRunning,
            activeAlert: coordinator.alerts.activeSorted.first.map {
                StageResolver.AlertSnapshot(title: $0.title, body: $0.body,
                                            raisedAt: $0.raisedAt, rules: $0.rules)
            },
            severity: coordinator.monitor.latest?.status.severity ?? "ok",
            linkUp: coordinator.monitor.latest?.link.up ?? true
        ))
    }

    @ViewBuilder
    private var stageSection: some View {
        switch stage {
        case .healthy: healthyStage
        case .watching(let sev): watchingStage(sev)
        case .alerted(let alert): alertStage(alert)
        case .testing: testingStage
        case .paused(let reason): pausedStage(reason)
        case .skewed(let message): skewedStage(message)
        }
    }

    private var healthyStage: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("All good — watching")
                    .font(.callout).fontWeight(.semibold)
            }
            Text(quietLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastCheck = lastCheckLine {
                Text("Last check \(lastCheck.relative)\(lastCheck.badge.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let detail = statusDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// The card that shows the moment the CLI's verdict turns but before an
    /// alert's dwell has elapsed — the state that used to be silently
    /// `.healthy` for up to 15–25 s while the timeline below already showed
    /// the drop. `critical` reads red, `warn` reads amber; the body is the
    /// CLI's own blurb for the worst firing rule (sourced via
    /// `coordinator.headline`, the same path the menu-bar headline already
    /// uses), never a verdict authored in Swift. The tertiary line tells
    /// the user why no alert has fired yet — "confirming before notifying
    /// you" — so a red card with no banner notification is not read as a
    /// bug.
    private func watchingStage(_ sev: StageResolver.WatchingSeverity) -> some View {
        let isCritical = sev == .critical
        let tint: Color = isCritical ? .red : .orange
        let title = isCritical ? "Detecting a network problem"
                               : "Watching — something needs attention"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isCritical ? "exclamationmark.triangle.fill"
                                             : "exclamationmark.triangle")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(2)
            }
            // `headline` already returns the worst firing rule's blurb for
            // severity warn/critical, and the no-connection line when the
            // link is down — both exactly the prose this card needs.
            Text(coordinator.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(isCritical ? "Confirming before notifying you…"
                            : "Will alert if this keeps up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// "Nothing has changed in 3 h 12 m · on HomeNet 5G" — the headline
    /// reassurance metric. Time comes from the event store, name from
    /// the CLI-derived network identity.
    private var quietLine: String {
        var parts: [String] = []
        if let since = NetworkEvent.timeSinceLast(coordinator.eventLog.events,
                                                  now: .now) {
            let f = DateComponentsFormatter()
            f.allowedUnits = since >= 3600 ? [.hour, .minute] : [.minute]
            f.unitsStyle = .abbreviated
            if let s = f.string(from: since) {
                parts.append("Nothing has changed in \(s)")
            }
        } else {
            parts.append("Watching for changes")
        }
        if let name = coordinator.wifiDisplayName { parts.append("on \(name)") }
        return parts.joined(separator: " · ")
    }

    private func alertStage(_ alert: StageResolver.AlertSnapshot) -> some View {
        // Folded into the CTA's own label rather than a second caption
        // beside it — one more active alert is a fact about *this*
        // button's destination (the full report lists all of them), not a
        // second thing on the stage competing for the same attention the
        // worst alert already has.
        let moreCount = max(coordinator.alerts.activeSorted.count - 1, 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(alert.title)
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(2)
            }
            // CLI prose verbatim — the interim body until a scan
            // enriches it, then diagnosis[].summary.
            Text(alert.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(attributionText(for: alert))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(moreCount > 0 ? "See full report (+\(moreCount))" : "See full report") {
                    openActivity()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// "rule G2 · 3m ago" — the attribution line the spec calls for. Omits
    /// the rule segment cleanly for the four event-driven alerts (VPN
    /// dropped, public IP changed, ...) that carry no rule at all, rather
    /// than printing "rule  · 3m ago".
    private func attributionText(for alert: StageResolver.AlertSnapshot) -> String {
        guard let rule = alert.rules.sorted().first else {
            return RelativeTime.string(from: alert.raisedAt)
        }
        return "rule \(rule) · \(RelativeTime.string(from: alert.raisedAt))"
    }

    private var testingStage: some View {
        VStack(alignment: .leading, spacing: 4) {
            scanningRow
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func pausedStage(_ reason: String?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Monitoring paused")
                    .font(.callout).fontWeight(.semibold)
            }
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if !appSettings.monitoringEnabled {
                Button("Resume monitoring") {
                    appSettings.monitoringEnabled = true
                    coordinator.setMonitoring(enabled: true)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    private func skewedStage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("The netdiag command needs attention")
                    .font(.callout).fontWeight(.semibold)
            }
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { openWindow(id: WindowID.settings) }
                .controlSize(.small)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Instruments (fixed; never move between states)

    private var instrumentSection: some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(spacing: 0) {
                InstrumentCell(label: "Internet", value: internetValue.text,
                               tint: internetValue.tint)
                InstrumentCell(label: "Loss", value: lossValue.text,
                               tint: lossValue.tint)
                InstrumentCell(label: "Down", value: speedValues.down,
                               unit: "Mbps")
                InstrumentCell(label: "Up", value: speedValues.up,
                               unit: "Mbps")
            }
            if let age = speedValues.age {
                Text("speeds from test \(age)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Divider()
            HStack(spacing: 0) {
                InstrumentCell(label: "Router",
                               value: routerInfo?.ping ?? "—",
                               tint: routerTint)
                InstrumentCell(label: "Wi-Fi", value: wifiCell.value,
                               unit: wifiCell.unit, tint: wifiCell.tint)
                InstrumentCell(label: "VPN",
                               value: vpnActive ? (vpnName ?? "on") : "off",
                               tint: vpnActive ? .primary : .secondary)
                LocationCell(countryISO: countryISO, publicIP: publicIP)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// Categories of the currently fired rules, resolved through the
    /// CLI's own catalog — the CLI names the rule, the catalog names
    /// what the rule is about, and this view only maps "about" to a
    /// cell. No rule list is hardcoded here to drift out of date.
    private var firedCategories: Set<String> {
        guard let catalog = coordinator.rulesCatalog.catalog else { return [] }
        return Set(firedRules.compactMap { catalog[$0]?.category })
    }

    private var firedRules: Set<String> {
        Set(coordinator.monitor.latest?.status.rules ?? [])
    }

    private var internetValue: (text: String, tint: Color) {
        guard let rtt = coordinator.monitor.latest?.internet.rttAvgMs else {
            return ("—", .primary)
        }
        return ("\(Int(rtt.rounded())) ms",
                firedCategories.contains("internet") ? .red : .primary)
    }

    /// Green here means something the other cells never claim: the CLI's
    /// own severity, not this view's opinion of a number. Available only
    /// once the catalog has loaded — without it there is no way to tell
    /// "no rule fired" from "the catalog to check against never arrived",
    /// so the safer read is no tint at all rather than a false all-clear.
    private var lossValue: (text: String, tint: Color) {
        guard let loss = coordinator.monitor.latest?.internet.lossPct else {
            return ("—", .primary)
        }
        let text = String(format: "%.1f%%", loss)
        if firedCategories.contains("internet") { return (text, .red) }
        guard coordinator.rulesCatalog.catalog != nil else { return (text, .primary) }
        return (text, coordinator.monitor.latest?.status.severity == "ok" ? .green : .primary)
    }

    private var routerTint: Color {
        firedCategories.contains("router") ? .red : .primary
    }

    /// RSSI arrives from the monitor's medium tier (`_mon_probe_wifi_signal`,
    /// 60 s cadence) — but that probe needs `sudo -n`, which the ordinary
    /// unprivileged GUI does not have, so `wifi.rssi` stays null for the
    /// entire session in the common case. A live CoreWLAN read (gated on
    /// Location Services, the same gate `--wifi-only` uses) is therefore
    /// the PRIMARY source for most users; the monitor's own value is used
    /// whenever it is present (a `sudo netdiag`-launched app, or a future
    /// privileged helper). `rssiValue() == 0` is CoreWLAN's own
    /// "unavailable", not a real reading. The read itself is cached in
    /// `coreWLANRSSI` rather than taken here — see that property and the
    /// view's `.task(id:)` for why a per-render syscall would be wrong.
    private var resolvedRSSI: Int? {
        coordinator.monitor.latest?.wifi?.rssi ?? coreWLANRSSI
    }

    /// The Wi-Fi cell's (value, unit, tint) — the CLI's own word as the
    /// value and the raw dBm underneath (`SignalScale.cellContent`,
    /// shared with `HomeView`'s Wi-Fi row), with one override on top: a
    /// fired `wifi`-category rule always wins the tint, the same red every
    /// other cell in this grid uses for "the CLI found a problem here" —
    /// a band's own tone answers "how strong is this reading", not "did
    /// the CLI diagnose something", and the two can disagree (VPN-masked
    /// WiFi rules, a flapping link the diagnosis names but a strong
    /// instantaneous RSSI reading wouldn't).
    private var wifiCell: (value: String, unit: String?, tint: Color) {
        guard coordinator.monitor.latest?.link.isWiFi == true else {
            return ("wired", nil, .secondary)
        }
        let content = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
        guard firedCategories.contains("wifi") else { return content }
        return (content.value, content.unit, .red)
    }

    private func refreshCoreWLANRSSIIfNeeded() {
        guard coordinator.monitor.latest?.link.isWiFi == true,
              coordinator.monitor.latest?.wifi?.rssi == nil,
              coordinator.locationPermissions.isAuthorized,
              let live = CWWiFiClient.shared().interface()?.rssiValue(),
              live != 0 else {
            coreWLANRSSI = nil
            return
        }
        coreWLANRSSI = live
    }

    private var speedValues: (down: String, up: String, age: String?) {
        if let speed = coordinator.latestSpeedTest {
            let age = coordinator.latestSpeedTestAt
                .map { RelativeTime.string(from: $0) }
            return (speed.downMbps.map { String(Int($0.rounded())) } ?? "—",
                    speed.upMbps.map { String(Int($0.rounded())) } ?? "—",
                    age)
        }
        if let stored = coordinator.history.latestSpeedTest(
            for: coordinator.monitor.latest?.network.historyJoinID) {
            return (String(Int(stored.down.rounded())),
                    stored.up.map { String(Int($0.rounded())) } ?? "—",
                    RelativeTime.string(from: stored.date))
        }
        return ("—", "—", nil)
    }

    // MARK: - Heartbeat

    private var heartbeatSection: some View {
        VStack(spacing: 2) {
            HeartbeatStrip(samples: coordinator.monitor.recent,
                           flatlined: !coordinator.monitor.isRunning
                                      || coordinator.monitor.isPaused)
            HStack {
                // The live probe interval, straight from the monitor's own
                // emitted `cadence_s` — so it reads "every 5s" while
                // healthy, "every 3s" once degraded engages, and "every 2s"
                // during a latency-test burst, and changes the moment the
                // monitor's cadence does rather than from a settings
                // snapshot. A user watching the card turn red sees the
                // probe rate ramp up at the same time, which is the
                // evidence that the app is investigating rather than
                // sitting on a stale green. Falls back to the configured
                // fast interval before the first sample lands.
                if coordinator.monitor.isRunning && !coordinator.monitor.isPaused {
                    let cadence = coordinator.monitor.latest?.status.cadenceS
                        ?? Defaults.fastInterval
                    Text(coordinator.monitor.isBursting
                         ? "every \(cadence)s · test"
                         : "every \(cadence)s")
                    if let stats = heartbeatStats {
                        Text("· min \(stats.min) · avg \(stats.avg) · max \(stats.max) ms")
                    }
                } else {
                    Text("monitoring off")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    /// Same 60-sample window `HeartbeatStrip` plots, summarized as
    /// min/avg/max so the strip's shape has numbers beside it. Hidden
    /// below two points: a min/avg/max of one number is not a range.
    private var heartbeatStats: (min: Int, avg: Int, max: Int)? {
        let values = coordinator.monitor.recent.suffix(60)
            .compactMap { $0.internet.rttAvgMs }
        guard values.count >= 2, let minV = values.min(), let maxV = values.max()
        else { return nil }
        let avgV = values.reduce(0, +) / Double(values.count)
        return (Int(minV.rounded()), Int(avgV.rounded()), Int(maxV.rounded()))
    }

    // MARK: - Timeline

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
            let recent = Array(coordinator.eventLog.within(hours: 24).prefix(3))
            if recent.isEmpty {
                Text("No changes in the last 24 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            } else {
                ForEach(recent) { EventRow(event: $0) }
            }
        }
    }

    // MARK: - The one CTA

    private var checkButton: some View {
        Button {
            coordinator.runScan(depth: .full, reason: "you asked")
        } label: {
            HStack {
                Image(systemName: "stethoscope")
                Text("Check My Connection")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(coordinator.isScanning)
    }

    // MARK: - System Controls & Footer

    private var controlsSection: some View {
        VStack(spacing: 2) {
            dropdownButton("Open Dashboard", icon: "rectangle.on.rectangle") {
                // Explicit, not just "whatever the window happens to be
                // showing": without this, a single earlier trip to Activity
                // (via `openActivity()` below) would leave every later
                // "Open Dashboard" landing back on Activity forever — this
                // row's whole point is Home. `MainWindow` applies the
                // request whether it's opening the window fresh (`.task`)
                // or the window is already open (`.onChange`).
                coordinator.requestedDestination = .home
                openWindow(id: WindowID.dashboard)
                // Opened from a menu-bar extra the window arrives behind
                // whatever is frontmost; every other window-opening row
                // here activates for the same reason.
                NSApp.activate(ignoringOtherApps: true)
            }

            dropdownButton(appSettings.monitoringEnabled ? "Pause Monitoring" : "Resume Monitoring",
                           icon: appSettings.monitoringEnabled ? "pause" : "play") {
                let enabled = !appSettings.monitoringEnabled
                appSettings.monitoringEnabled = enabled
                coordinator.setMonitoring(enabled: enabled)
            }

            // Open Dashboard + Pause/Resume above the line, Settings + Quit
            // below — the same horizontal inset the rows themselves use
            // (via `dropdownButton`) so it doesn't run flush to the panel
            // edge the way an unpadded Divider would.
            Divider()
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)

            dropdownButton("Settings…", icon: "gearshape") {
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            }

            dropdownButton("Quit netdiag", icon: "power") {
                coordinator.stop()
                NSApp.terminate(nil)
            }

            HStack {
                Text("netdiag v\(Defaults.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if coordinator.updateChecker.hasUpdate {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button {
                        coordinator.updateChecker.downloadAndInstallUpdate()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Update available (\(coordinator.updateChecker.availableRelease?.cleanVersion ?? "new"))")
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 4)
        }
    }

    private func dropdownButton(_ title: String, icon: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    // MARK: - Kept glance values (unchanged from the pre-redesign dropdown)

    /// Only two branches survive here: every other case `statusDetail` used
    /// to cover (scanning, paused, monitoring off, a skewed CLI) now has its
    /// own stage above `healthyStage` and can no longer reach this code —
    /// `stage` returns `.healthy` only once scanning, paused-for-any-reason,
    /// monitoring-off and skewed have all tested false.
    private var statusDetail: String? {
        if coordinator.monitor.isBursting {
            return "Latency test running — sampling every \(appSettings.latencyTestInterval)s."
        }
        if let sample = coordinator.monitor.latest, sample.status.icmpFiltered {
            return "This network blocks ping — real connections are fine."
        }
        return nil
    }

    private var scanningRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                ScanProgressLine(progress: coordinator.progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Button("Cancel check") { coordinator.cancelScan() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openActivity() {
        coordinator.requestedDestination = .activity
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var publicIP: String? {
        let ip = coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
            ?? coordinator.hydratedReport?.run.publicInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
            ?? coordinator.hydratedReport?.run.publicInfo.countryISO
    }

    private var routerInfo: (ping: String, ip: String?)? {
        let ip = coordinator.monitor.latest?.link.gateway
            ?? coordinator.latestRun?.snapshot.gateway.ip
            ?? coordinator.hydratedReport?.run.gateway.ip
        let rtt = coordinator.monitor.latest?.gateway.rttAvgMs
            ?? coordinator.latestRun?.snapshot.gateway.rttAvgMs
            ?? coordinator.hydratedReport?.run.gateway.rttAvgMs
        let loss = coordinator.monitor.latest?.gateway.lossPct
            ?? coordinator.latestRun?.snapshot.gateway.lossPct
            ?? coordinator.hydratedReport?.run.gateway.lossPct

        guard let current = rtt else {
            if let ip {
                return ("—", ip)
            }
            return nil
        }
        let pingStr: String
        if let loss, loss > 0 {
            pingStr = String(format: "%.0f ms · %.0f%% loss", current, loss)
        } else {
            pingStr = String(format: "%.0f ms", current)
        }
        return (pingStr, ip)
    }

    private var vpnActive: Bool {
        coordinator.monitor.latest?.vpn.active
            ?? coordinator.latestRun?.snapshot.vpn.active
            ?? coordinator.hydratedReport?.run.vpn.active ?? false
    }

    private var vpnName: String? {
        coordinator.monitor.latest?.vpn.name
            ?? coordinator.latestRun?.snapshot.vpn.name
            ?? coordinator.hydratedReport?.run.vpn.name
    }

    private var lastCheckLine: (relative: String, badge: String?)? {
        switch coordinator.reportSource {
        case .live(let run):
            return (RelativeTime.string(from: run.finishedAt), coordinator.scanKind.isEmpty ? nil : coordinator.scanKind)
        case .stored(let detail):
            return (RelativeTime.string(from: detail.run.date), "from history")
        case .none:
            return nil
        }
    }
}

/// Menu-like hover highlight for dropdown rows.
struct HighlightingButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : .clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
