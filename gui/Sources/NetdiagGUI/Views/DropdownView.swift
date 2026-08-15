import SwiftUI

/// Layer two of four: the dropdown status menu.
///
/// Designed for quick at-a-glance networking health:
/// 1. Status & connection check at top
/// 2. Active alerts (if any)
/// 3. At-a-glance facts: Public IPv4 (with flag), Internet Ping, Router Ping, Local IP, Latest Speed
/// 4. Quick tests: Run speed test, Live latency monitor
/// 5. Open dashboard (prominent & stand-alone)
/// 6. System controls: Pause/resume, Settings, Quit, and version footer
struct DropdownView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroSection
            
            if !coordinator.alerts.activeSorted.isEmpty {
                alertStrip
                    .padding(.top, Theme.Spacing.xs)
            }
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            networkGlancePanel
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            testsSection
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            dashboardSection
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            controlsSection
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Hero & Connection Check

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: coordinator.currentHealth.symbol)
                    .foregroundStyle(coordinator.currentHealth.tint)
                    .font(.title3)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.headline)
                        .font(.callout)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)

            // Primary Check Action
            if coordinator.isScanning {
                scanningRow
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, 4)
            } else {
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
                .controlSize(.regular)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 4)

                if let lastCheck = lastCheckLine {
                    HStack(spacing: 4) {
                        Text("Last check: \(lastCheck.relative)")
                        if let badge = lastCheck.badge {
                            Text("· \(badge)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 1)
                }
            }
        }
    }

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

    // MARK: - Alert Strip

    @ViewBuilder
    private var alertStrip: some View {
        let alerts = coordinator.alerts.activeSorted
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(alerts.prefix(3)) { alert in
                    Button(action: openActivity) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "bell.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(alert.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(RelativeTime.string(from: alert.raisedAt))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.sm + 2)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12),
                                   in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.card)
                                .stroke(Color.orange.opacity(0.25))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private func openActivity() {
        coordinator.requestedDestination = .activity
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - At-a-Glance Network Glance Panel

    private var networkGlancePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Network Name (if available & clean)
            if let name = cleanNetworkName {
                LabeledContent {
                    Text(name).fontWeight(.medium)
                } label: {
                    Text("Network")
                }
            }

            // Public IP (IPv4 with Country Flag)
            if let ip = publicIP {
                LabeledContent {
                    HStack(spacing: 4) {
                        if let flag = Flag.emoji(forISOCode: countryISO) { Text(flag) }
                        Text(ip)
                            .font(Theme.Font.compactMonospace)
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("Public IP")
                }
            }

            // Internet Ping: Current prominent, average / loss smaller
            if let ping = internetPing {
                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ping.current)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        if let detail = ping.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("Internet Ping")
                }
            }

            // Router: Ping + Clickable Admin IP
            if let router = routerInfo {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(router.ping)

                        if let ip = router.ip {
                            Button {
                                if let url = URL(string: "http://\(ip)") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(ip)
                                        .font(Theme.Font.compactMonospace)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Open router admin page (http://\(ip))")
                        }
                    }
                } label: {
                    Text("Router")
                }
            }

            // Latest Speed (Down & Up)
            LabeledContent {
                Text(speedString)
                    .foregroundStyle(hasSpeedMeasurement ? .primary : .secondary)
            } label: {
                Text("Speed")
            }

            // Active VPN Indicator
            if vpnActive {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.blue)
                    Text(vpnName ?? "VPN active")
                    Spacer()
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .font(.caption)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 2)
    }

    // MARK: - Quick Tests Section

    private var testsSection: some View {
        VStack(spacing: 2) {
            dropdownButton("Run speed test", icon: "gauge.with.dots.needle.bottom.50percent") {
                coordinator.runSpeedTest()
            }

            dropdownButton("Live latency monitor", icon: "waveform.path.ecg") {
                coordinator.startLatencyTest()
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Dashboard Section

    private var dashboardSection: some View {
        VStack(spacing: 2) {
            dropdownButton("Open dashboard", icon: "chart.bar.doc.horizontal") {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - System Controls & Footer

    private var controlsSection: some View {
        VStack(spacing: 2) {
            dropdownButton(appSettings.monitoringEnabled ? "Pause monitoring" : "Resume monitoring",
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

    // MARK: - Derived Glance Values

    private var cleanNetworkName: String? {
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
                return nil // Hide ugly redacted wifi label per user request
            }
            return raw
        }
        return nil
    }

    private var publicIP: String? {
        let ip = coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var localIP: String? {
        let ip = coordinator.monitor.latest?.link.ip
            ?? coordinator.latestRun?.snapshot.interfaceInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
    }

    private var internetPing: (current: String, detail: String?)? {
        if let current = coordinator.monitor.latest?.internet.rttAvgMs {
            let currentStr = String(format: "%.0f ms", current)
            let loss = coordinator.monitor.latest?.internet.lossPct
            let pings = coordinator.monitor.recent.compactMap { $0.internet.rttAvgMs }
            var detailParts: [String] = []
            if pings.count >= 3 {
                let avg = pings.reduce(0, +) / Double(pings.count)
                detailParts.append(String(format: "avg %.0f ms", avg))
            }
            if let loss {
                detailParts.append(String(format: "%.0f%% loss", loss))
            }
            let detail = detailParts.isEmpty ? nil : "(\(detailParts.joined(separator: " · ")))"
            return (currentStr, detail)
        }

        if let tcp = coordinator.monitor.latest?.tcp.targets.first(where: { $0.ok && $0.elapsedMs != nil }) {
            let currentStr = String(format: "%.0f ms", tcp.elapsedMs!)
            return (currentStr, "(TCP)")
        }

        if let current = coordinator.latestRun?.snapshot.internetLatency.rttAvgMs {
            let currentStr = String(format: "%.0f ms", current)
            let loss = coordinator.latestRun?.snapshot.internetLatency.lossPct
            if let loss {
                return (currentStr, "(\(String(format: "%.0f%% loss", loss)))")
            }
            return (currentStr, nil)
        }

        return nil
    }

    private var routerInfo: (ping: String, ip: String?)? {
        let ip = coordinator.monitor.latest?.link.gateway
            ?? coordinator.latestRun?.snapshot.gateway.ip
        guard let current = coordinator.monitor.latest?.gateway.rttAvgMs
            ?? coordinator.latestRun?.snapshot.gateway.rttAvgMs else {
            if let ip {
                return ("—", ip)
            }
            return nil
        }
        let loss = coordinator.monitor.latest?.gateway.lossPct
            ?? coordinator.latestRun?.snapshot.gateway.lossPct
        let pingStr: String
        if let loss {
            pingStr = String(format: "%.0f ms · %.0f%% loss", current, loss)
        } else {
            pingStr = String(format: "%.0f ms", current)
        }
        return (pingStr, ip)
    }

    private var speedString: String {
        if let speed = coordinator.latestSpeedTest {
            if let down = speed.downMbps, let up = speed.upMbps {
                return String(format: "%.0f Mbps ↓ · %.0f Mbps ↑", down, up)
            } else if let down = speed.downMbps {
                return String(format: "%.0f Mbps ↓", down)
            }
        }
        if let speed = coordinator.latestRun?.snapshot.speedtest {
            if let down = speed.downMbps, let up = speed.upMbps {
                return String(format: "%.0f Mbps ↓ · %.0f Mbps ↑", down, up)
            } else if let down = speed.downMbps {
                return String(format: "%.0f Mbps ↓", down)
            }
        }
        let currentNetID = coordinator.monitor.latest?.network.id
        let runs = coordinator.history.document.runs
        for run in runs.reversed() {
            if let netID = currentNetID, !netID.isEmpty, run.networkID != netID { continue }
            if let down = run.metrics["speedtest.down_mbps"] {
                let up = run.metrics["speedtest.up_mbps"]
                if let up {
                    return String(format: "%.0f Mbps ↓ · %.0f Mbps ↑", down, up)
                }
                return String(format: "%.0f Mbps ↓", down)
            }
        }
        return "Not tested yet"
    }

    private var hasSpeedMeasurement: Bool {
        speedString != "Not tested yet"
    }

    private var vpnActive: Bool {
        coordinator.monitor.latest?.vpn.active
            ?? coordinator.latestRun?.snapshot.vpn.active ?? false
    }

    private var vpnName: String? {
        coordinator.monitor.latest?.vpn.name ?? coordinator.latestRun?.snapshot.vpn.name
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
