import SwiftUI

/// Layer two of four: the dropdown.
///
/// Written for the non-technical user. One plain sentence about the state
/// of things, the network they are on, and a button that starts a check.
/// Everything an expert wants is one click further in, never here.
struct DropdownView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            Divider()
            networkPanel
            Divider()
            actions
        }
        .padding(.vertical, 8)
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: coordinator.currentHealth.symbol)
                .foregroundStyle(tint)
                .font(.title3)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                // Verbatim from the CLI whenever there is anything to say:
                // most_likely_root_cause, or an active alert's body once a
                // scan has enriched it.
                Text(coordinator.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Why the app is not currently watching, when it is not. A stopped
    /// indicator with no explanation reads as a broken app.
    private var statusDetail: String? {
        if coordinator.isScanning {
            let elapsed = Int(Date().timeIntervalSince(coordinator.scanStartedAt ?? Date()))
            return "Running a check… (\(elapsed)s)"
        }
        if let reason = coordinator.monitor.pauseReason {
            return "Paused — \(reason)."
        }
        if !Defaults.monitoringEnabled { return "Turn monitoring on to watch continuously." }
        if let error = coordinator.monitor.lastError { return error }
        if let sample = coordinator.monitor.latest, sample.status.icmpFiltered {
            // TCP-1. Worth saying out loud: on a hotel or corporate network
            // the ping numbers everywhere else in this app are meaningless,
            // and a user who doesn't know that will read them as a fault.
            return "This network blocks ping — real connections are fine (rule TCP-1)."
        }
        return nil
    }

    // MARK: - Network panel

    private var networkPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(networkName).fontWeight(.medium)
            } label: {
                Text("Network")
            }

            if let ip = publicIP {
                LabeledContent {
                    HStack(spacing: 4) {
                        if let flag = Flag.emoji(forISOCode: countryISO) { Text(flag) }
                        Text(ip)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("Public IP")
                }
            }

            if let rtt = gatewayRTT {
                LabeledContent {
                    Text(rtt)
                } label: {
                    Text("Router")
                }
            }

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 2) {
            if coordinator.isScanning {
                Button {
                    coordinator.cancelScan()
                } label: {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Cancel check")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                dropdownButton("Check my connection", icon: "stethoscope") {
                    coordinator.runScan(depth: .full, reason: "you asked")
                }
                dropdownButton("Quick check", icon: "bolt") {
                    coordinator.runScan(depth: .quick, reason: "you asked")
                }
            }

            Divider().padding(.vertical, 4)

            dropdownButton("Open dashboard", icon: "chart.bar.doc.horizontal") {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
            dropdownButton(copied ? "Copied to clipboard" : "Copy shareable report",
                           icon: copied ? "checkmark" : "doc.on.clipboard") {
                Task {
                    copied = await coordinator.copyShareableReport()
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            dropdownButton(Defaults.monitoringEnabled ? "Pause monitoring" : "Resume monitoring",
                           icon: Defaults.monitoringEnabled ? "pause" : "play") {
                coordinator.setMonitoring(enabled: !Defaults.monitoringEnabled)
                NotificationCenter.default.post(name: .netdiagSettingsChanged, object: nil)
            }
            dropdownButton("Settings…", icon: "gearshape") {
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            dropdownButton("Quit netdiag", icon: "power") {
                coordinator.stop()
                NSApp.terminate(nil)
            }
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

    // MARK: - Derived values

    private var tint: Color {
        switch coordinator.currentHealth {
        case .healthy:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private var networkName: String {
        if let id = coordinator.monitor.latest?.network.id, !id.isEmpty {
            return coordinator.history.displayName(for: id)
        }
        return coordinator.monitor.latest?.network.label
            ?? coordinator.latestRun?.snapshot.network.label
            ?? "Not connected"
    }

    private var publicIP: String? {
        let ip = coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
    }

    private var gatewayRTT: String? {
        guard let sample = coordinator.monitor.latest else { return nil }
        guard let rtt = sample.gateway.rttAvgMs else { return nil }
        let loss = sample.gateway.lossPct
        // "0% loss" and "not measured" are different statements. Say the
        // first only when it was measured.
        if let loss { return String(format: "%.0f ms · %.0f%% loss", rtt, loss) }
        return String(format: "%.0f ms", rtt)
    }

    private var vpnActive: Bool {
        coordinator.monitor.latest?.vpn.active
            ?? coordinator.latestRun?.snapshot.vpn.active ?? false
    }

    private var vpnName: String? {
        coordinator.monitor.latest?.vpn.name ?? coordinator.latestRun?.snapshot.vpn.name
    }
}

/// Menu-like hover highlight. `.buttonStyle(.plain)` inside a
/// `.menuBarExtraStyle(.window)` panel gives no affordance at all, and a
/// row that doesn't light up doesn't read as clickable.
struct HighlightingButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.accentColor.opacity(0.85) : .clear)
                    .padding(.horizontal, 6)
            )
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
