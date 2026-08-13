import SwiftUI

/// Where a network card leads.
///
/// The route carries the group's id rather than the `Network` struct: the
/// struct is a snapshot of a merge that the user can change while this view
/// is on screen, and pushing a copy of it would pin the list to how the
/// grouping looked at the moment the row was tapped.
struct NetworkRoute: Hashable {
    let networkID: String
}

/// Every check ever run on one network, newest first.
///
/// Nothing here calls the CLI. `--history` already returns each run's
/// timestamp, severity, rules and root cause, and `HistoryStore` is holding
/// all of it — so a network with 1,915 checks lists instantly, and only
/// opening one costs a process. `List` is lazy, so the row count does not
/// matter either.
struct RunListView: View {
    let networkID: String
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var filter = Filter.all

    private var store: HistoryStore { coordinator.history }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Problems only"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Divider()
            List {
                if unopenableCount > 0 { unopenableNotice }
                if days.isEmpty {
                    emptyState
                } else {
                    ForEach(days) { day in
                        Section(day.label) {
                            ForEach(day.runs) { row($0) }
                        }
                    }
                }
            }
        }
        .navigationDestination(for: RunRoute.self) { route in
            RunDetailView(route: route)
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Filter to the checks the CLI marked as a warning or worse")
            }
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.displayName(for: networkID)).font(.headline)
            Text(visibleRuns.count == allRuns.count
                 ? "\(allRuns.count) check(s)"
                 : "\(visibleRuns.count) of \(allRuns.count) check(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ run: HistoryDocument.Run) -> some View {
        if let runID = run.runID {
            NavigationLink(value: RunRoute(runID: runID, networkID: networkID)) {
                rowContent(run)
            }
        } else {
            // Listed but not navigable — see `unopenableNotice`.
            rowContent(run)
        }
    }

    private func rowContent(_ run: HistoryDocument.Run) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: run.health.symbol)
                .foregroundStyle(run.health.tint)
                .frame(width: 16)
            Text(run.date.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.headline)
                    .foregroundStyle(run.diagnosisCount == 0 ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !run.rules.isEmpty { chips(run.rules) }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Rule ids straight from the CLI, one `RuleChip` each. With a rules
    /// catalog loaded, tapping one opens its plain-English explanation;
    /// without one, this is the same inert capsule row this view always
    /// rendered — see `RuleChip`'s header.
    private func chips(_ rules: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(rules, id: \.self) { rule in
                RuleChip(ruleID: rule)
            }
        }
    }

    // MARK: - Empty and degraded states

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if filter == .problems {
                Label("No warnings on this network", systemImage: "checkmark.circle")
                    .font(.callout)
                Text("None of the \(allRuns.count) check(s) recorded against this network was marked a warning or a critical. Switch to All to see them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No checks recorded for this network", systemImage: "tray")
                    .font(.callout)
                Text("Checks appear here as soon as netdiag records one against this network. Turn on background checks in Settings to record one every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    /// Version skew, stated rather than hidden. `--show` addresses a run by
    /// the id `--history` stamps on it, and a netdiag from before that
    /// stamps none — so those rows can be listed but not opened. The app and
    /// the CLI are installed separately, so this is a normal state to be in
    /// for a while, not an error.
    private var unopenableNotice: some View {
        Label {
            Text("\(unopenableCount) of these check(s) can't be opened: the netdiag command line on this Mac is older than this app and didn't record an id for them. Updating netdiag makes them openable.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    // MARK: - Data

    private var allRuns: [HistoryDocument.Run] {
        store.runs(networkID: networkID, window: .all).sorted { $0.date > $1.date }
    }

    private var visibleRuns: [HistoryDocument.Run] {
        filter == .problems ? allRuns.filter(isProblem) : allRuns
    }

    private var unopenableCount: Int {
        visibleRuns.reduce(0) { $0 + ($1.runID == nil ? 1 : 0) }
    }

    /// The same set NetworksView already counts as incidents: the severities
    /// the CLI itself stamped on the run.
    private func isProblem(_ run: HistoryDocument.Run) -> Bool {
        run.severity == "warn" || run.severity == "critical"
    }

    private struct Day: Identifiable {
        let id: String
        let label: String
        let runs: [HistoryDocument.Run]
    }

    /// One section per calendar day, newest first. `visibleRuns` is already
    /// in that order, so the days come out of it in order too.
    private var days: [Day] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryDocument.Run]] = [:]
        for run in visibleRuns {
            let day = calendar.startOfDay(for: run.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(run)
        }
        return order.map {
            Day(id: "\($0.timeIntervalSince1970)", label: dayLabel($0), runs: buckets[$0] ?? [])
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        // "Today" and "Yesterday" where they apply: most of the time the
        // interesting checks are the recent ones, and a full date makes the
        // reader work out which of them that is.
        f.doesRelativeDateFormatting = true
        return f.string(from: day)
    }
}
