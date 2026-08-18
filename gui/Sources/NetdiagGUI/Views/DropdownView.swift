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
/// 3. Instrument grid — fixed 4x2: internet ping, internet loss, download,
///    upload / router, Wi-Fi, VPN, location. Cells never disappear; an
///    unmeasured value renders as "—".
/// 4. Heartbeat strip — a thin live sparkline of internet ping, labeled
///    with min/avg/max, proving monitoring is alive.
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
    /// `wifiValue` — see that property's header. Refreshed by the `.task`
    /// below, at most once per incoming monitor sample.
    @State private var coreWLANRSSI: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stageSection
                .padding(.horizontal, Theme.Spacing.md)

            checkButton
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            instrumentSection
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            heartbeatSection
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

    private enum Stage {
        case skewed(String)
        case testing
        case paused(String?)
        case alerted(AlertEngine.ActiveAlert)
        case healthy
    }

    // Paused checks sit above the skewed check on purpose: a user who just
    // turned monitoring off, or whose display just slept, must see
    // "Monitoring paused" — not a stale capabilities-handshake error left
    // over from before the pause, which `lastError` can still be holding.
    private var stage: Stage {
        if coordinator.isScanning { return .testing }
        if !appSettings.monitoringEnabled {
            return .paused(nil)
        }
        if coordinator.monitor.isPausedForAnyReason {
            return .paused(coordinator.monitor.pauseReason)
        }
        if let error = coordinator.monitor.lastError,
           !coordinator.monitor.isRunning {
            return .skewed(error)
        }
        if let alert = coordinator.alerts.activeSorted.first {
            return .alerted(alert)
        }
        return .healthy
    }

    @ViewBuilder
    private var stageSection: some View {
        switch stage {
        case .healthy: healthyStage
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
        if let name = cleanNetworkName { parts.append("on \(name)") }
        return parts.joined(separator: " · ")
    }

    private func alertStage(_ alert: AlertEngine.ActiveAlert) -> some View {
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
    private func attributionText(for alert: AlertEngine.ActiveAlert) -> String {
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
                InstrumentCell(label: "Wi-Fi", value: wifiValue, tint: wifiTint)
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

    private var wifiTint: Color {
        firedCategories.contains("wifi") ? .red : .primary
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
    private var wifiValue: String {
        guard coordinator.monitor.latest?.link.isWiFi == true else {
            return "wired"
        }
        if let rssi = coordinator.monitor.latest?.wifi?.rssi {
            return "\(rssi) dBm"
        }
        if let live = coreWLANRSSI {
            return "\(live) dBm"
        }
        return "—"
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
            for: coordinator.monitor.latest?.network.id) {
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
                Text(coordinator.monitor.isRunning && !coordinator.monitor.isPaused
                     ? "internet ping · live" : "monitoring off")
                Spacer()
                if let stats = heartbeatStats {
                    Text("min \(stats.min) · avg \(stats.avg) · max \(stats.max) ms")
                }
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

    private var cleanNetworkName: String? {
        // If location permissions not authorized, only show custom user-assigned name
        if !coordinator.locationPermissions.isAuthorized {
            if let id = coordinator.monitor.latest?.network.id, !id.isEmpty {
                let custom = coordinator.history.displayName(for: id)
                if !custom.isEmpty && custom != id && !custom.contains("<redacted>") && !custom.contains("hidden by macOS") && !custom.starts(with: "wifi:mac=") {
                    return custom
                }
            }
            return nil
        }
        if let id = coordinator.monitor.latest?.network.id, !id.isEmpty {
            let custom = coordinator.history.displayName(for: id)
            if !custom.isEmpty && custom != id && !custom.contains("<redacted>") && !custom.contains("hidden by macOS") {
                return custom
            }
        }
        let raw = coordinator.monitor.latest?.network.label
            ?? coordinator.latestRun?.snapshot.network.label
        if let raw, !raw.isEmpty {
            if raw.contains("<redacted>") || raw.contains("hidden by macOS") || raw.starts(with: "wifi:mac=") {
                return nil // Hide ugly redacted wifi label
            }
            return raw
        }
        return nil
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
