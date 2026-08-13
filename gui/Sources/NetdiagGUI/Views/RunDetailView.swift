import SwiftUI

/// Which stored run to open. The network id travels alongside so the header
/// can name the network without waiting for the fetch to come back.
struct RunRoute: Hashable {
    let runID: String
    let networkID: String
}

/// One stored check: the same report card the Status tab shows, plus how it
/// compares to the rest of this network's history, plus the expert layer.
///
/// The comparison is the reason this is worth opening rather than a
/// screenshot of the past. "3.7 ms" means nothing without "and this network
/// usually does 3.2 ms" — and the CLI is what knows the second half, so
/// every word of it arrives here already written.
struct RunDetailView: View {
    let route: RunRoute
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @State private var detail: RunDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail {
                    header(detail)
                    RunReportView(snapshot: detail.run,
                                  comparison: detail.comparison,
                                  showRuleIDs: appSettings.expertExpanded)
                    expertDisclosure(detail)
                } else if let error {
                    failure(error)
                } else {
                    loading
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: route.runID) { await load() }
    }

    // MARK: - Header

    private func header(_ detail: RunDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: detail.run.worstSeverity.symbol)
                    .foregroundStyle(detail.run.worstSeverity.tint)
                Text(detail.run.date.formatted(date: .abbreviated, time: .standard))
                    .font(.title3)
            }
            Text(subtitle(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Counting, not judgement. `context` carries the plain facts — how many
    /// runs this network has and where this one sits among them — and the
    /// CLI keeps everything that weighs them in `comparison`.
    private func subtitle(_ detail: RunDetail) -> String {
        let name = coordinator.history.displayName(for: route.networkID)
        guard detail.context.position > 0, detail.context.runsOnNetwork > 0 else { return name }
        return "\(name) · check \(detail.context.position) of \(detail.context.runsOnNetwork)"
    }

    // MARK: - Expert layer

    private func expertDisclosure(_ detail: RunDetail) -> some View {
        @Bindable var appSettings = appSettings
        return DisclosureGroup(isExpanded: $appSettings.expertExpanded) {
            // The panel's raw-JSON viewer shows what `--show` actually
            // printed, which is this run's stored record plus the context
            // and comparison computed around it — the bytes, not a
            // re-encode of the partial model above.
            ExpertPanel(run: detail.asRunResult)
                .padding(.top, 8)
        } label: {
            Text("Technical detail").font(.headline)
        }
    }

    // MARK: - Loading and failure

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // A fetch is a bash start plus a scan of the whole run store —
            // fast, but not free, and a blank pane for a third of a second
            // reads as a broken screen.
            Text("Opening this check…").foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This check couldn't be opened", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await load() } }
        }
        .padding(.top, 24)
    }

    private func load() async {
        error = nil
        do {
            detail = try await coordinator.details.detail(for: route.runID)
        } catch {
            detail = nil
            self.error = error.localizedDescription
        }
    }
}
