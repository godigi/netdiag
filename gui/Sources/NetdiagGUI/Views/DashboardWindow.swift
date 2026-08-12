import SwiftUI

/// The main window: report card, history, networks.
struct DashboardWindow: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var tab = Tab.report

    enum Tab: String, CaseIterable, Identifiable {
        case report = "Status"
        case history = "History"
        case networks = "Networks"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch tab {
            case .report:   DashboardView()
            case .history:  HistoryView()
            case .networks: NetworksView()
            }
        }
        .task { await coordinator.history.load() }
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
    @State private var expertExpanded = Defaults.expertExpanded

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let run = coordinator.latestRun {
                    RunReportView(snapshot: run.snapshot, showRuleIDs: expertExpanded)
                    expertDisclosure(run)
                } else {
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
                if let run = coordinator.latestRun {
                    Text("Last checked \(run.finishedAt.formatted(date: .abbreviated, time: .shortened)) · took \(String(format: "%.0f", run.duration))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if coordinator.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    // No percentage: --json emits only at the very end, so
                    // there is nothing to be a percentage *of*. An elapsed
                    // timer and an honest estimate beat a fake bar.
                    Text(elapsedLabel).monospacedDigit().font(.caption)
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

    private var elapsedLabel: String {
        let elapsed = Int(Date().timeIntervalSince(coordinator.scanStartedAt ?? Date()))
        return "\(elapsed)s"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No check has run yet.").font(.headline)
            Text("netdiag is watching your connection continuously in the background. Run a full check to see the detail behind it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = coordinator.lastRunError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 24)
    }

    // MARK: - Expert layer

    private func expertDisclosure(_ run: RunResult) -> some View {
        DisclosureGroup(isExpanded: $expertExpanded) {
            ExpertPanel(run: run)
                .padding(.top, 8)
        } label: {
            Text("Technical detail").font(.headline)
        }
        .onChange(of: expertExpanded) { _, new in
            Defaults.expertExpanded = new
        }
    }
}
