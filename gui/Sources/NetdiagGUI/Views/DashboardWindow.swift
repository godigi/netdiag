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

/// Layer three of four: the report card.
///
/// Report-card rows summarise what was measured; the diagnosis prose below
/// is the CLI's, rendered verbatim. The expert layer hangs off the bottom
/// as a disclosure whose open/closed state persists — never a mode chosen
/// at first launch, because asking a user "are you technical?" gets the
/// wrong answer in both directions.
struct DashboardView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var expertExpanded = Defaults.expertExpanded

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let run = coordinator.latestRun {
                    reportCard(run.snapshot)
                    diagnoses(run.snapshot)
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

    // MARK: - Report card

    private func reportCard(_ snapshot: RunSnapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(rows(snapshot)) { row in
                HStack {
                    Image(systemName: row.health.symbol)
                        .foregroundStyle(colour(row.health))
                        .frame(width: 18)
                    Text(row.label).frame(width: 140, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(row.value == "not measured" ? .secondary : .primary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                Divider()
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let health: Health
    }

    /// Rows describe *measurements*, not verdicts — the health tint comes
    /// from whether the CLI's own diagnosis array named the relevant rule,
    /// so this view never compares a number to a threshold.
    private func rows(_ s: RunSnapshot) -> [Row] {
        let firedRules = Set(s.diagnosis.compactMap(\.rule))
        func health(_ rules: [String]) -> Health {
            let hits = s.diagnosis.filter { d in d.rule.map(rules.contains) ?? false }
            if hits.contains(where: { $0.severity == "critical" }) { return .critical }
            if hits.contains(where: { $0.severity == "warn" }) { return .warning }
            return .healthy
        }
        _ = firedRules

        var out: [Row] = []
        out.append(Row(label: "Router",
                       value: format(s.gateway.rttAvgMs, "%.1f ms", loss: s.gateway.lossPct),
                       health: health(["G1", "G2", "G3", "DI-1"])))
        out.append(Row(label: "Internet",
                       value: format(s.internetLatency.rttAvgMs, "%.0f ms",
                                     loss: s.internetLatency.lossPct),
                       health: health(["L1", "L2", "P1", "P2", "N1", "N1b"])))
        out.append(Row(label: "Name lookups (DNS)",
                       value: s.dns.isEmpty ? "not measured"
                            : "\(s.dns.filter(\.ok).count) of \(s.dns.count) resolvers OK",
                       health: health(["D1", "DH-2"])))
        if let wifi = s.wifi {
            out.append(Row(label: "Wi-Fi signal",
                           value: wifi.rssi.map { "\($0) dBm" } ?? "needs sudo to measure",
                           health: health(["W1", "W2", "WS-1", "WD-1"])))
        }
        out.append(Row(label: "Under load",
                       value: s.bufferbloat.gwGrade.map { grade in
                            s.bufferbloat.gwDeltaMs.map { String(format: "grade %@ (+%.0f ms)", grade, $0) } ?? "grade \(grade)"
                       } ?? "not measured",
                       health: health(["B1", "B2"])))
        out.append(Row(label: "Packet size (MTU)",
                       value: s.mtu.effective.map { "\($0) bytes" } ?? "not measured",
                       health: health(["M1"])))
        if let speed = s.speedtest {
            out.append(Row(label: "Speed",
                           value: [speed.downMbps.map { String(format: "%.0f Mbps down", $0) },
                                   speed.upMbps.map { String(format: "%.0f up", $0) }]
                                .compactMap { $0 }.joined(separator: " · "),
                           health: health(["BL-1"])))
        }
        out.append(Row(label: "Clock",
                       value: s.ntp.driftSeconds.map { String(format: "%+.2f s off", $0) } ?? "not measured",
                       health: health(["NT-1"])))
        return out
    }

    /// "not measured" rather than a zero. The CLI's schema draws that line
    /// deliberately — treating an unmeasured value as zero is what produced
    /// false diagnoses in earlier versions — and the UI has to hold it too.
    private func format(_ value: Double?, _ fmt: String, loss: Double?) -> String {
        guard let value else { return "not measured" }
        var text = String(format: fmt, value)
        if let loss, loss > 0 { text += String(format: " · %.0f%% loss", loss) }
        return text
    }

    // MARK: - Diagnoses

    private func diagnoses(_ s: RunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What we found").font(.headline)
            if s.diagnosis.isEmpty {
                Label("Nothing obviously wrong — your network looks healthy.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(s.diagnosis) { d in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: d.health.symbol)
                        .foregroundStyle(colour(d.health))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        // Verbatim. The CLI already writes this for a
                        // non-technical reader; rewording it here would be
                        // the app inventing a second opinion.
                        Text(d.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        if expertExpanded, let rule = d.rule {
                            Text("rule \(rule) — see docs/DIAGNOSIS-RULES.md")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
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

    private func colour(_ h: Health) -> Color {
        switch h {
        case .healthy:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }
}
