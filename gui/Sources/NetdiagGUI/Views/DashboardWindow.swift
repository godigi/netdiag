import SwiftUI

/// Declared outside the view so the coordinator can ask for one. The
/// dropdown's "Latency test" has to open the Live tab, and the window it
/// wants may not exist at the moment it asks.
enum DashboardTab: String, CaseIterable, Identifiable {
    case report = "Status"
    case live = "Live"
    case history = "History"
    case networks = "Networks"
    var id: String { rawValue }
}

/// The main window: report card, live stream, history, networks.
struct DashboardWindow: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var tab = DashboardTab.report

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(DashboardTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch tab {
            case .report:   DashboardView()
            case .live:     LiveView()
            case .history:  HistoryView()
            case .networks: NetworksView()
            }
        }
        .task {
            // Both paths are needed: `.task` catches a request made while
            // the window did not exist yet, `onChange` catches one made
            // while it was already open behind another app.
            if let requested = coordinator.consumeRequestedTab() { tab = requested }
            await coordinator.history.load()
        }
        .onChange(of: coordinator.requestedTab) { _, new in
            guard new != nil, let requested = coordinator.consumeRequestedTab() else { return }
            tab = requested
        }
    }
}

/// Layer three of four: the live run.
///
/// The card itself is `RunReportView`, shared with the stored runs the
/// Networks tab browses — a live run passes no comparison because there is
/// nothing to compare it against until it is in the store. The expert layer
/// hangs off the bottom as a disclosure whose open/closed state persists —
/// never a mode chosen at first launch, because asking a user "are you
/// technical?" gets the wrong answer in both directions.
struct DashboardView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

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
                    expertDisclosure(run)
                case .stored(let detail):
                    // Comparison chips come free: `detail` is a `--show`
                    // response, and RunReportView already knows how to
                    // render one — RunDetailView passes the identical pair.
                    RunReportView(snapshot: detail.run, comparison: detail.comparison,
                                  showRuleIDs: appSettings.expertExpanded)
                    expertDisclosure(detail.asRunResult)
                case nil:
                    emptyState
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: - Expert layer

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
