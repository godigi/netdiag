import SwiftUI

/// Layer two of four: the dropdown.
///
/// A status instrument, not a launcher. Built from
/// `nimbalyst-local/mockups/netdiag-dropdown.mockup.html`'s three states —
/// idle-with-alerts, "More tests" expanded, a check running. The hierarchy
/// mirrors the mockup top to bottom: hero verdict → every active alert →
/// the facts about this network → one obvious action (plus an explained
/// menu of the others) → footer utilities. Everything an expert wants is
/// one click further in, never here.
///
/// "More tests" is an inline expansion (`moreTestsExpanded`), not a SwiftUI
/// `Menu`: the fourth entry needs a focused `TextField` for a hostname, and
/// an `NSMenu`-backed `Menu` — a *second* tracking loop layered over this
/// panel's own — is not a place a `TextField` can reliably keep focus. That
/// is the "fights the panel" case this task's brief flagged in advance, so
/// this went straight to the sanctioned fallback rather than shipping a
/// `Menu` for three rows and a different mechanism for the fourth. The
/// inline expansion also keeps every row reachable the same way (scoped
/// accessibility, no menu tracking loop to drive at all), which is what
/// this file's verification actually exercised end to end.
struct DropdownView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false
    /// True for the ~10 s `netdiag --redact --json` child is actually
    /// running — the state the old button never had, which made a second
    /// click during that window look like the first one did nothing.
    @State private var copyInFlight = false
    @State private var moreTestsExpanded = false
    @State private var targetPromptOpen = false
    @State private var targetHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            alertStrip
            Divider()
            networkPanel
            Divider()
            actions
            Divider().padding(.vertical, Theme.Spacing.xs)
            footer
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: coordinator.currentHealth.symbol)
                .foregroundStyle(coordinator.currentHealth.tint)
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
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// Why the app is not currently watching, when it is not. A stopped
    /// indicator with no explanation reads as a broken app.
    private var statusDetail: String? {
        // The scanning case is handled by the progress line in `actions`,
        // which reports phases rather than a bare elapsed count.
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
            // TCP-1. Worth saying out loud: on a hotel or corporate network
            // the ping numbers everywhere else in this app are meaningless,
            // and a user who doesn't know that will read them as a fault.
            // The rule id itself stays out of this default sentence — it
            // returns once the rule-chip work gives it somewhere to land.
            return "This network blocks ping — real connections are fine."
        }
        return nil
    }

    // MARK: - Alert strip

    /// One compact row per active alert — *every* active alert, where the
    /// hero above only ever has room for the worst one's body. Hidden
    /// entirely when nothing is active rather than reserving empty space
    /// for it.
    @ViewBuilder
    private var alertStrip: some View {
        let alerts = coordinator.alerts.activeSorted
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(alerts.prefix(3)) { alert in
                    alertRow(alert)
                }
                if alerts.count > 3 {
                    moreAlertsRow(count: alerts.count - 3)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)
        }
    }

    private func alertRow(_ alert: AlertEngine.ActiveAlert) -> some View {
        Button(action: openActivity) {
            HStack(spacing: Theme.Spacing.sm) {
                // A bell rather than a severity glyph: neither
                // `AlertEngine.ActiveAlert` nor `AlertDefinition` carries a
                // severity today, so there is nothing truthful to tint by
                // yet — this is the "or a bell" fallback the brief allows.
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
            .padding(.vertical, 7)
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

    private func moreAlertsRow(count: Int) -> some View {
        Button(action: openActivity) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("+\(count) more").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    /// Every alert row and the "+N more" row: routes to Activity. `.activity`
    /// is a placeholder section until T13 builds the real alert-center
    /// timeline (`MainWindow.ActivityPlaceholder`), so today this opens the
    /// dashboard on an honest "nothing behind this yet" screen rather than
    /// somewhere the tapped alert can't be found at all.
    private func openActivity() {
        coordinator.requestedDestination = .activity
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
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
                            .font(Theme.Font.compactMonospace)
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

            if let lastCheck = lastCheckLine {
                LabeledContent {
                    HStack(spacing: 4) {
                        Text(lastCheck.relative)
                        if let badge = lastCheck.badge {
                            Text("· \(badge)").foregroundStyle(.tertiary)
                        }
                    }
                } label: {
                    Text("Last check")
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
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Actions

    private var actions: some View {
        // No wrapper padding here: rows drawn with HighlightingButtonStyle
        // pad themselves 12 pt to line up with the footer's rows, so a
        // wrapper inset would push them 12 pt further right than the rows
        // below the divider. Only the non-row content — the primary button,
        // its caption, and the scanning/expansion cards — pads itself.
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if coordinator.isScanning {
                scanningRow
                    .padding(.horizontal, Theme.Spacing.md)
            } else {
                primaryButton
                    .padding(.horizontal, Theme.Spacing.md)
                Text("usually takes \(NetdiagRunner.Depth.full.estimate)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 2)
                moreTestsRow
                if moreTestsExpanded {
                    moreTestsExpansion
                        .padding(.horizontal, Theme.Spacing.md)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// The one obvious action, replacing the four flat, unlabeled buttons
    /// this panel used to open with.
    private var primaryButton: some View {
        Button {
            coordinator.runScan(depth: .full, reason: "you asked")
        } label: {
            Text("Check my connection")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var moreTestsRow: some View {
        Button {
            if moreTestsExpanded { targetPromptOpen = false; targetHost = "" }
            withAnimation(.easeInOut(duration: 0.15)) { moreTestsExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "testtube.2").frame(width: 16)
                Text("More tests")
                Spacer(minLength: 0)
                Image(systemName: moreTestsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    /// Every test states what it does and how long it takes — the mockup's
    /// state 2. Durations come from `NetdiagRunner.Depth.estimate` or, for
    /// the latency test, the app's own configured burst duration; nothing
    /// here retypes a number the runner or `AppSettings` already owns.
    private var moreTestsExpansion: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreTestRow(title: "Quick check",
                       caption: "\(NetdiagRunner.Depth.quick.estimate) — skips speed & load tests") {
                coordinator.runScan(depth: .quick, reason: "you asked")
                closeMoreTests()
            }
            Divider()
            moreTestRow(title: "Speed test", caption: speedTestCaption) {
                coordinator.runSpeedTest()
                closeMoreTests()
            }
            Divider()
            moreTestRow(title: "Latency test",
                       caption: "watch your router respond live for \(Int(appSettings.latencyTestDuration)) s") {
                coordinator.startLatencyTest()
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
                closeMoreTests()
            }
            Divider()
            if targetPromptOpen {
                targetPromptRow
            } else {
                moreTestRow(title: "Test a connection to a site…",
                           caption: "ping, route and DNS for one host, e.g. github.com") {
                    targetPromptOpen = true
                }
            }
        }
        .padding(Theme.Spacing.xs)
        .cardStyle()
    }

    private func moreTestRow(title: String, caption: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    /// The fourth "More tests" row, in place: the runner already supports a
    /// positional target host (`NetdiagRunner.Depth.arguments` appends it),
    /// so this needs only somewhere to type one. An `NSMenu` item is not a
    /// reliable home for a focused `TextField`, which is why this whole
    /// section is an inline expansion rather than a `Menu` — see this
    /// file's header.
    private var targetPromptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test a connection to a site…")
                .font(.caption).fontWeight(.medium)
            HStack(spacing: 6) {
                TextField("github.com", text: $targetHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit(submitTargetTest)
                Button("Test", action: submitTargetTest)
                    .controlSize(.small)
                    .disabled(trimmedTargetHost.isEmpty)
                Button("Cancel") {
                    targetPromptOpen = false
                    targetHost = ""
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var trimmedTargetHost: String {
        targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitTargetTest() {
        let host = trimmedTargetHost
        guard !host.isEmpty else { return }
        // A quick check, not a full one: this is "does this one host work",
        // and the results land through the normal report flow — the same
        // adopt-as-report path any other `runScan` call takes.
        coordinator.runScan(depth: .quick, reason: "testing \(host)", target: host)
        targetHost = ""
        closeMoreTests()
    }

    private func closeMoreTests() {
        moreTestsExpanded = false
        targetPromptOpen = false
    }

    /// Same one-line phase readout the dashboard renders as a grid
    /// (`ScanProgressLine`), plus Cancel — this panel has room for one line,
    /// not a grid.
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
            Button("Cancel") { coordinator.cancelScan() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            openNetdiagRow
            copyReportRow
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
        }
    }

    /// While a check is running this gains a trailing hint — the mockup's
    /// "watch the check live" — since the dashboard is the one place that
    /// shows the full phase grid this panel's one-line version doesn't have
    /// room for.
    private var openNetdiagRow: some View {
        Button {
            openWindow(id: WindowID.dashboard)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").frame(width: 16)
                Text("Open netdiag")
                Spacer(minLength: 0)
                if coordinator.isScanning {
                    Text("watch the check live")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    /// The dead-button fix: an inline spinner and a "~10 s" caption for the
    /// whole time `netdiag --redact --json` is actually running, not just a
    /// label flip once it's already done.
    private var copyReportRow: some View {
        Button {
            guard !copyInFlight else { return }
            copyInFlight = true
            Task {
                let ok = await coordinator.copyShareableReport()
                copyInFlight = false
                copied = ok
                guard ok else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            HStack(spacing: 8) {
                if copyInFlight {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard").frame(width: 16)
                }
                Text(copied ? "Copied" : "Copy report for my ISP")
                Spacer(minLength: 0)
                if copyInFlight {
                    // Threaded from the same estimate the runner owns, not
                    // retyped — the report is a --quick check under the hood.
                    Text(NetdiagRunner.Depth.quick.estimate)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
        .disabled(copyInFlight)
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

    /// Carries the last result once there is one, so pressing it a second
    /// time is an informed choice. A speed is a measurement and nothing
    /// more — no grade, no colour, no opinion about whether it is enough.
    /// The estimate up front is the tool's own wall-clock, threaded from
    /// `NetdiagRunner.Depth.estimate` rather than retyped.
    private var speedTestCaption: String {
        guard let speed = coordinator.latestSpeedTest, let down = speed.downMbps else {
            return NetdiagRunner.Depth.speedOnly.estimate
        }
        return String(format: "%@ · last: %.0f Mbps down",
                      NetdiagRunner.Depth.speedOnly.estimate, down)
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

    /// "2 h ago · full check" / "Today 09:12 · quick check" — whichever
    /// report `HomeView` would currently show, read the same way
    /// `NetdiagCoordinator.reportSource` already resolves it: a live run's
    /// own `finishedAt`, or a hydrated/stored run's recorded timestamp.
    /// `nil` when there is no report at all, which is what keeps this row
    /// nil-tolerant rather than showing a blank "Last check" line.
    private var lastCheckLine: (relative: String, badge: String?)? {
        switch coordinator.reportSource {
        case .live(let run):
            return (RelativeTime.string(from: run.finishedAt), run.snapshot.modeBadge)
        case .stored(let detail):
            return (RelativeTime.string(from: detail.run.date), detail.run.modeBadge)
        case nil:
            return nil
        }
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
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(hovering ? Color.accentColor.opacity(0.85) : .clear)
                    .padding(.horizontal, 6)
            )
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
