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
    }

    // MARK: - Stage

    private enum Stage {
        case skewed(String)
        case testing
        case paused(String?)
        case alerted(AlertEngine.ActiveAlert)
        case healthy
    }

    private var stage: Stage {
        if let error = coordinator.monitor.lastError,
           !coordinator.monitor.isRunning {
            return .skewed(error)
        }
        if coordinator.isScanning { return .testing }
        if !appSettings.monitoringEnabled {
            return .paused(nil)
        }
        if coordinator.monitor.isPausedForAnyReason {
            return .paused(coordinator.monitor.pauseReason)
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
        VStack(alignment: .leading, spacing: 4) {
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
                Text(RelativeTime.string(from: alert.raisedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("See full report") { openActivity() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
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
                InstrumentCell(label: "Wi-Fi", value: wifiValue)
                InstrumentCell(label: "VPN",
                               value: vpnActive ? (vpnName ?? "on") : "off",
                               tint: vpnActive ? .primary : .secondary)
                LocationCell(countryISO: countryISO, publicIP: publicIP)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// Cell tint keys off the CLI's fired rules, never off the number:
    /// the rule IDs are the verdict, the map below is only "which cell
    /// does this rule talk about". The internet-side cells (ping and
    /// loss) share L1/L2; the router cell reads G1-G3 — the two probes
    /// measure different hops, so a cell tints only for rules about
    /// that hop.
    private static let internetRules: Set<String> = ["L1", "L2"]
    private static let routerRules: Set<String> = ["G1", "G2", "G3"]

    private var firedRules: Set<String> {
        Set(coordinator.monitor.latest?.status.rules ?? [])
    }

    private var internetValue: (text: String, tint: Color) {
        guard let rtt = coordinator.monitor.latest?.internet.rttAvgMs else {
            return ("—", .primary)
        }
        let bad = !firedRules.isDisjoint(with: Self.internetRules)
        return ("\(Int(rtt.rounded())) ms", bad ? .red : .primary)
    }

    private var lossValue: (text: String, tint: Color) {
        guard let loss = coordinator.monitor.latest?.internet.lossPct else {
            return ("—", .primary)
        }
        let bad = !firedRules.isDisjoint(with: Self.internetRules)
        return (String(format: "%.1f%%", loss), bad ? .red : .green)
    }

    private var routerTint: Color {
        firedRules.isDisjoint(with: Self.routerRules) ? .primary : .red
    }

    /// The monitor's slow-tier RSSI covers most of a session, but not the
    /// gap between launch and its first slow-tier cycle — falling back to
    /// a live CoreWLAN read (when Location Services is authorized; RSSI is
    /// gated behind it the same as `--wifi-only`) keeps the cell from
    /// reading "—" for that whole window. `rssiValue() == 0` is CoreWLAN's
    /// own "unavailable", not a real reading.
    private var wifiValue: String {
        guard coordinator.monitor.latest?.link.isWiFi == true else {
            return "wired"
        }
        if let rssi = coordinator.monitor.latest?.wifi?.rssi {
            return "\(rssi) dBm"
        }
        if coordinator.locationPermissions.isAuthorized,
           let live = CWWiFiClient.shared().interface()?.rssiValue(),
           live != 0 {
            return "\(live) dBm"
        }
        return "—"
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

    private var statusDetail: String? {
        if coordinator.isScanning { return nil }
        if coordinator.monitor.isBursting {
            return "Latency test running — sampling every \(appSettings.latencyTestInterval)s."
        }
        if let reason = coordinator.monitor.pauseReason {
            return "Paused — \(reason)."
        }
        if !appSettings.monitoringEnabled { return "Turn monitoring on to watch continuously." }
        if let error = coordinator.monitor.lastError { return error }
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
