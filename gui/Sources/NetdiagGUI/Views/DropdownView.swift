import SwiftUI
import CoreWLAN
import AppKit

/// Layer two of four: the dropdown status menu.
///
/// Designed for quick at-a-glance networking health:
/// 1. Status & connection check at top with contextual remedies
/// 2. Active alerts (if any)
/// 3. Visual 3-Hop Link Path bar (Mac ──▶ Router ──▶ Internet)
/// 4. At-a-glance facts: Wi-Fi, Signal, Public IP, Pings, Speed, VPN
/// 5. Quick action grid: Copy Summary, Speed Test, Dashboard
/// 6. System controls: Live Latency, Pause/resume, Settings, Quit, and version footer
struct DropdownView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    @State private var copiedSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroSection
            
            if !coordinator.alerts.activeSorted.isEmpty {
                alertStrip
                    .padding(.top, Theme.Spacing.xs)
            }

            contextualRemedy
            
            Divider().padding(.vertical, Theme.Spacing.xs)

            linkPathSection
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            networkGlancePanel
            
            Divider().padding(.vertical, Theme.Spacing.xs)
            
            quickActionBar
            
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

    // MARK: - Contextual Remedy Button

    @ViewBuilder
    private var contextualRemedy: some View {
        if let sample = coordinator.monitor.latest, sample.status.severity == "critical" || sample.status.severity == "warn" {
            let rules = sample.status.rules
            if rules.contains("G2") || rules.contains("G3"), let gwIP = coordinator.monitor.latest?.link.gateway {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Router packet loss detected.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let url = URL(string: "http://\(gwIP)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("Open Router Admin")
                            .font(.caption2)
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 4)
            } else if rules.contains("G1") || rules.contains("W1") {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Weak Wi-Fi signal. Move closer or switch to 5 GHz.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 4)
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

    // MARK: - Visual 3-Hop Link Path Bar

    private var linkPathSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("LINK PATH")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)

            HStack(spacing: 0) {
                // Mac Node
                pathNode(icon: "laptopcomputer", title: "Mac", subtitle: localIP ?? "en0", color: macNodeColor)

                // Local Link Connector
                pathConnector(icon: localLinkIcon, label: localLinkLabel, color: localLinkColor)

                // Router Node
                pathNode(icon: "network", title: "Router", subtitle: routerPingShort, color: routerNodeColor)

                // Internet Link Connector
                pathConnector(icon: "arrow.right", label: internetPingShort, color: internetLinkColor)

                // Internet Node
                pathNode(icon: "globe", title: "Internet", subtitle: internetStatusShort, color: internetNodeColor)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private func pathNode(icon: String, title: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func pathConnector(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Rectangle().fill(color.opacity(0.4)).frame(height: 1.5)
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
                Rectangle().fill(color.opacity(0.4)).frame(height: 1.5)
            }
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(width: 52)
    }

    // Path colors and labels
    private var macNodeColor: Color {
        if let link = coordinator.monitor.latest?.link, !link.up { return .red }
        return .green
    }

    private var localLinkIcon: String {
        if let isWiFi = coordinator.monitor.latest?.link.isWiFi, isWiFi {
            return "wifi"
        }
        return "cable.connector"
    }

    private var localLinkLabel: String {
        if let iface = CWWiFiClient.shared().interface() {
            let rssi = iface.rssiValue()
            if rssi != 0 {
                return "\(rssi) dBm"
            }
        }
        if let isWiFi = coordinator.monitor.latest?.link.isWiFi, isWiFi {
            return "Wi-Fi"
        }
        return "LAN"
    }

    private var localLinkColor: Color {
        if let sample = coordinator.monitor.latest {
            if !sample.link.up { return .red }
            if let loss = sample.gateway.lossPct, loss >= 20 { return .red }
            if let loss = sample.gateway.lossPct, loss > 0 { return .orange }
            if let iface = CWWiFiClient.shared().interface(), iface.rssiValue() < -75 && iface.rssiValue() != 0 {
                return .orange
            }
        }
        return .green
    }

    private var routerPingShort: String {
        if let rtt = coordinator.monitor.latest?.gateway.rttAvgMs {
            let loss = coordinator.monitor.latest?.gateway.lossPct ?? 0
            if loss > 0 {
                return String(format: "%.0fms (%.0f%%)", rtt, loss)
            }
            return String(format: "%.0f ms", rtt)
        }
        return "—"
    }

    private var routerNodeColor: Color {
        if let sample = coordinator.monitor.latest {
            if !sample.link.up { return .secondary }
            if let loss = sample.gateway.lossPct, loss >= 20 { return .red }
            if let loss = sample.gateway.lossPct, loss > 0 { return .orange }
        }
        return .green
    }

    private var internetPingShort: String {
        if let rtt = coordinator.monitor.latest?.internet.rttAvgMs {
            let loss = coordinator.monitor.latest?.internet.lossPct ?? 0
            if loss > 0 {
                return String(format: "%.0fms (%.0f%%)", rtt, loss)
            }
            return String(format: "%.0f ms", rtt)
        }
        return "—"
    }

    private var internetLinkColor: Color {
        if let sample = coordinator.monitor.latest {
            if !sample.link.up { return .secondary }
            if let loss = sample.internet.lossPct, loss >= 20 { return .red }
            if let loss = sample.internet.lossPct, loss > 0 { return .orange }
            if sample.publicInfo.ok == false { return .red }
        }
        return .green
    }

    private var internetStatusShort: String {
        if let country = countryISO, let flag = Flag.emoji(forISOCode: country) {
            return flag
        }
        if let sample = coordinator.monitor.latest {
            if sample.publicInfo.ok == false || sample.internet.lossPct == 100 {
                return "Offline"
            }
        }
        return "Online"
    }

    private var internetNodeColor: Color {
        if let sample = coordinator.monitor.latest {
            if !sample.link.up || sample.publicInfo.ok == false || sample.internet.lossPct == 100 { return .red }
            if let loss = sample.internet.lossPct, loss >= 20 { return .red }
            if let loss = sample.internet.lossPct, loss > 0 { return .orange }
        }
        return .green
    }

    // MARK: - At-a-Glance Network Glance Panel

    private var networkGlancePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wi-Fi details (Only displayed when permissions are enabled and connected to Wi-Fi)
            if let wifi = wifiGlanceInfo {
                if let ssid = wifi.ssid {
                    LabeledContent {
                        Text(ssid).fontWeight(.medium)
                    } label: {
                        Text("Wi-Fi")
                    }
                }
                LabeledContent {
                    Text(wifi.signal)
                        .foregroundStyle(wifi.isWeak ? .orange : .primary)
                } label: {
                    Text("Wi-Fi Signal")
                }
            } else if let name = cleanNetworkName {
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

    // MARK: - Quick Action Bar (Copy Summary, Speed Test, Dashboard)

    private var quickActionBar: some View {
        HStack(spacing: 6) {
            Button(action: copyDiagnosticSummary) {
                HStack(spacing: 4) {
                    Image(systemName: copiedSummary ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copiedSummary ? .green : .secondary)
                    Text(copiedSummary ? "Copied" : "Copy Summary")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                coordinator.runSpeedTest()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt")
                        .foregroundStyle(.secondary)
                    Text("Speed Test")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar")
                        .foregroundStyle(.secondary)
                    Text("Dashboard")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func copyDiagnosticSummary() {
        var lines: [String] = []
        let dateStr = Date().formatted(date: .abbreviated, time: .shortened)
        lines.append("Netdiag Diagnostic Summary (\(dateStr))")
        lines.append("─────────────────────────────────────")
        lines.append("Status: \(coordinator.headline)")
        
        if let wifi = wifiGlanceInfo {
            if let ssid = wifi.ssid {
                lines.append("Wi-Fi: \(ssid) (\(wifi.signal))")
            } else {
                lines.append("Wi-Fi Signal: \(wifi.signal)")
            }
        } else if let name = cleanNetworkName {
            lines.append("Network: \(name)")
        }
        
        if let local = localIP {
            lines.append("Local IP: \(local)")
        }
        
        if let router = routerInfo {
            let ipStr = router.ip.map { " (\($0))" } ?? ""
            lines.append("Router: \(router.ping)\(ipStr)")
        }
        
        if let ping = internetPing {
            let detail = ping.detail.map { " \($0)" } ?? ""
            lines.append("Internet Ping: \(ping.current)\(detail)")
        }
        
        if let ip = publicIP {
            let flag = Flag.emoji(forISOCode: countryISO).map { "\($0) " } ?? ""
            lines.append("Public IP: \(flag)\(ip)")
        }
        
        if hasSpeedMeasurement {
            lines.append("Speed: \(speedString)")
        }
        
        if vpnActive {
            lines.append("VPN: Active (\(vpnName ?? "connected"))")
        }
        
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        
        copiedSummary = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedSummary = false
        }
    }

    // MARK: - System Controls & Footer

    private var controlsSection: some View {
        VStack(spacing: 2) {
            dropdownButton("Live latency monitor", icon: "waveform.path.ecg") {
                coordinator.startLatencyTest()
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }

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

    private var wifiGlanceInfo: (ssid: String?, signal: String, isWeak: Bool)? {
        guard coordinator.locationPermissions.isAuthorized else { return nil }
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        
        let ssid = iface.ssid()
        let rssi = iface.rssiValue()
        guard rssi != 0 else {
            if let ssid, !ssid.isEmpty {
                return (ssid, "Connected", false)
            }
            return nil
        }
        
        let chan = iface.wlanChannel()?.channelNumber
        let band: String?
        if let chan {
            if chan <= 14 { band = "2.4 GHz" }
            else if chan <= 177 { band = "5 GHz" }
            else { band = "6 GHz" }
        } else {
            band = nil
        }
        
        let rating: String
        let isWeak: Bool
        if rssi >= -55 {
            rating = "Excellent"
            isWeak = false
        } else if rssi >= -65 {
            rating = "Good"
            isWeak = false
        } else if rssi >= -75 {
            rating = "Fair"
            isWeak = false
        } else {
            rating = "Weak"
            isWeak = true
        }
        
        let signalDetail: String
        if let band {
            signalDetail = "\(rating) (\(rssi) dBm · \(band))"
        } else {
            signalDetail = "\(rating) (\(rssi) dBm)"
        }
        
        return (ssid, signalDetail, isWeak)
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

    private var localIP: String? {
        let ip = coordinator.monitor.latest?.link.ip
            ?? coordinator.latestRun?.snapshot.interfaceInfo.ip
            ?? coordinator.hydratedReport?.run.interfaceInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
            ?? coordinator.hydratedReport?.run.publicInfo.countryISO
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
            if let loss, loss > 0 {
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
            if let loss, loss > 0 {
                return (currentStr, "(\(String(format: "%.0f%% loss", loss)))")
            }
            return (currentStr, nil)
        }

        if let current = coordinator.hydratedReport?.run.internetLatency.rttAvgMs {
            let currentStr = String(format: "%.0f ms", current)
            let loss = coordinator.hydratedReport?.run.internetLatency.lossPct
            if let loss, loss > 0 {
                return (currentStr, "(\(String(format: "%.0f%% loss", loss)))")
            }
            return (currentStr, nil)
        }

        return nil
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
        if let speed = coordinator.hydratedReport?.run.speedtest {
            if let down = speed.downMbps, let up = speed.upMbps {
                return String(format: "%.0f Mbps ↓ · %.0f Mbps ↑", down, up)
            } else if let down = speed.downMbps {
                return String(format: "%.0f Mbps ↓", down)
            }
        }
        if let speed = coordinator.history.latestSpeedTest(for: coordinator.monitor.latest?.network.id) {
            if let up = speed.up {
                return String(format: "%.0f Mbps ↓ · %.0f Mbps ↑", speed.down, up)
            }
            return String(format: "%.0f Mbps ↓", speed.down)
        }
        return "Not tested yet"
    }

    private var hasSpeedMeasurement: Bool {
        speedString != "Not tested yet"
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
