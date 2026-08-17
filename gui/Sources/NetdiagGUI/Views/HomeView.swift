import SwiftUI

/// Home: "is my internet OK, and why?" — the question the sidebar's first
/// row answers. Hydrated from stored history on cold launch so this is
/// never empty (see `NetdiagCoordinator.hydrateFromHistoryIfNeeded`), and
/// it is the same report card the Networks section's stored runs use —
/// `RunReportView` — plus the expert layer as a disclosure whose open/closed
/// state persists rather than a mode chosen at first launch, because asking
/// a user "are you technical?" gets the wrong answer in both directions.
///
/// Moved here from `DashboardWindow.swift` verbatim, plus
/// one addition: the "Recent checks" card the redesign's mockup
/// (`nimbalyst-local/mockups/netdiag-main-window.mockup.html`) puts in
/// Home's right column. The expert disclosure moved to the bottom of the
/// page, after that card, to match the mockup's order — previously it sat
/// directly under the report card because nothing came after it.
struct HomeView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                locationWarningBanner

                if coordinator.isScanning {
                    ScanProgressView(progress: coordinator.progress)
                    Divider()
                }

                // Hoisted out of `emptyState`: a hydrated report replaces
                // that state the moment history has anything to show, and a
                // failed scan needs to surface whether or not the screen
                // underneath it is empty.
                if let error = coordinator.lastRunError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch coordinator.reportSource {
                case .live(let run):
                    RunReportView(snapshot: run.snapshot, showRuleIDs: appSettings.expertExpanded)
                case .stored(let detail):
                    // Comparison chips come free: `detail` is a `--show`
                    // response, and RunReportView already knows how to
                    // render one — RunDetailView passes the identical pair.
                    RunReportView(snapshot: detail.run, comparison: detail.comparison,
                                  showRuleIDs: appSettings.expertExpanded)
                case nil:
                    emptyState
                }

                recentChecksCard

                if let result = currentRunResult {
                    expertDisclosure(result)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            coordinator.locationPermissions.refresh()
        }
    }

    // MARK: - Location Banner

    @ViewBuilder
    private var locationWarningBanner: some View {
        if isConnectedToWiFi && !coordinator.locationPermissions.isAuthorized {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi network name & radio diagnostics are restricted")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("macOS requires Location Services to display your network name and diagnose local radio strength. Basic fault isolation (Router vs ISP) remains active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Enable in Settings" : "Allow") {
                    if coordinator.locationPermissions.isDeniedOrRestricted {
                        coordinator.locationPermissions.openSystemSettings()
                    } else {
                        coordinator.locationPermissions.requestAuthorization()
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var isConnectedToWiFi: Bool {
        if let isWiFi = coordinator.monitor.latest?.link.isWiFi {
            return isWiFi
        }
        if let run = coordinator.latestRun {
            return run.snapshot.wifi != nil
        }
        return true
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.headline)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = lastCheckedCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if coordinator.isScanning {
                HStack(spacing: 6) {
                    // The elapsed seconds stay even now that the phase list
                    // exists: the list says how far along the run is
                    // through a *declared* set of checks, and says nothing
                    // about how long the rest will take. The counter is the
                    // only honest thing to put next to it.
                    //
                    // Driven by a TimelineView because nothing else ticks
                    // once a second — during a scan the monitor is paused,
                    // so a counter recomputed on observation alone would
                    // sit frozen at whatever second the last event landed.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .monospacedDigit().font(.caption)
                    }
                    Button("Cancel") { coordinator.cancelScan() }
                }
            } else {
                Button("Run a check") {
                    coordinator.runScan(depth: .full, reason: "you asked")
                }
                .keyboardShortcut("r")
            }
        }
    }

    private func elapsedLabel(at now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(coordinator.scanStartedAt ?? now))
        return "\(max(elapsed, 0))s"
    }

    /// "Last checked …" for whichever report is on screen. A live run adds
    /// "· took Ns" — the process's own wall-clock, meaningful for a check
    /// that just ran. A stored one drops it: the process that produced a
    /// report hydrated from history exited long before this launch, and
    /// its duration says nothing about how long *this* check took. A stored
    /// one adds the network's name instead — hydration picks the newest
    /// check across every network this app has seen, so showing last
    /// week's office report with no label while the headline above talks
    /// about the network you're on right now would read as one contradictory
    /// screen. Mirrors `RunDetailView.subtitle`, which names the network
    /// the same way for the same reason.
    private var lastCheckedCaption: String? {
        switch coordinator.reportSource {
        case .live(let run):
            return "Last checked \(run.finishedAt.formatted(date: .abbreviated, time: .shortened)) · took \(String(format: "%.0f", run.duration))s"
        case .stored(let detail):
            let date = detail.run.date.formatted(date: .abbreviated, time: .shortened)
            guard let networkID = detail.context.networkID else {
                // An old `netdiag` whose `--show` predates `context`. Still
                // better than nothing, just without the network name.
                return "Last checked \(date)"
            }
            return "Last checked \(date) · \(coordinator.history.displayName(for: networkID))"
        case nil:
            return nil
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No check has run yet.").font(.headline)
            Text("netdiag is watching your connection continuously in the background. Run a full check to see the detail behind it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
    }

    // MARK: - Recent checks

    /// The mockup's right-column list, pulled out as its own card: the last
    /// few checks across every network, so a report on screen never hides
    /// that fresher ones exist elsewhere. `HistoryStore.recentChecks`
    /// already picks and orders these — the same call cold-launch
    /// hydration makes, so this card and the report above it are answering
    /// the same "what's the newest real look at any network?" question from
    /// two different angles.
    private var recentChecksCard: some View {
        let checks = coordinator.history.recentChecks(limit: 5)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recent checks").font(.headline)
            if checks.isEmpty {
                Text("Checks will appear here once netdiag has run a few.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(checks) { run in
                        recentCheckRow(run)
                        if run.id != checks.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Tappable only when the CLI stamped an id on this run — the same
    /// version-skew handling `RunListView` uses: a row without one is
    /// listed but inert rather than offering a push that would fail. The
    /// two cases render differently for the same reason `RunListView`
    /// pairs its list with `unopenableNotice`: a plain `.buttonStyle(.plain)`
    /// row gives no visual difference between "tap this" and "this just sits
    /// here", so the tappable row gets a trailing chevron and the inert one
    /// is dimmed with a tooltip explaining why.
    @ViewBuilder
    private func recentCheckRow(_ run: HistoryDocument.Run) -> some View {
        if let runID = run.runID {
            NavigationLink(value: RunRoute(runID: runID, networkID: run.networkID)) {
                recentCheckRowContent(run, openable: true)
            }
            .buttonStyle(.plain)
        } else {
            recentCheckRowContent(run, openable: false)
                .help("Recorded by an older netdiag — this check can be listed but not opened.")
        }
    }

    private func recentCheckRowContent(_ run: HistoryDocument.Run, openable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: run.health.symbol)
                .foregroundStyle(run.health.tint)
                .frame(width: 14)
            Text(RelativeTime.string(from: run.date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(run.headline)
                .font(.caption)
                .foregroundStyle(openable && run.diagnosisCount > 0 ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let badge = run.modeBadge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            if openable {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }


    // MARK: - Expert layer

    /// Whichever report is on screen, as the `RunResult` the expert
    /// disclosure and the raw-JSON viewer inside it both expect.
    private var currentRunResult: RunResult? {
        switch coordinator.reportSource {
        case .live(let run):        return run
        case .stored(let detail):   return detail.asRunResult
        case nil:                   return nil
        }
    }

    private func expertDisclosure(_ run: RunResult) -> some View {
        @Bindable var appSettings = appSettings
        return DisclosureGroup(isExpanded: $appSettings.expertExpanded) {
            ExpertPanel(run: run)
                .padding(.top, 8)
        } label: {
            Text("Technical detail").font(.headline)
        }
    }
}
