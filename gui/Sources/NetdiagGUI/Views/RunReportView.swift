import SwiftUI

/// The report card: one row per thing that was measured, then the CLI's own
/// prose about what it means.
///
/// One view for the run that just finished and for a run pulled out of the
/// store. Two would drift, and the stored card would be the copy that lags —
/// every change made to the live one would have to be remembered twice.
///
/// Rows describe *measurements*, not verdicts. A row's tint comes from
/// whether the CLI's own diagnosis array named the relevant rule, and its
/// comparison chip is the CLI's `summary` rendered verbatim. Nothing here
/// compares a number to a threshold or writes a sentence about one.
struct RunReportView: View {
    let snapshot: RunSnapshot
    /// nil for a live run: a run has nothing to be compared against until
    /// it is in the store.
    var comparison: RunDetail.Comparison?
    /// Whether each diagnosis shows its rule id. Passed in rather than read
    /// from `Defaults` so the captions appear the instant the enclosing
    /// expert disclosure is opened, not on the next launch.
    var showRuleIDs: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
            diagnoses
        }
    }

    // MARK: - Report card

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack {
                    Image(systemName: row.health.symbol)
                        .foregroundStyle(row.health.tint)
                        .frame(width: 18)
                    Text(row.label).frame(width: 140, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(row.value == "not measured" ? .secondary : .primary)
                    Spacer()
                    comparisonChip(row)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                Divider()
            }
        }
        .cardStyle()
    }

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let health: Health
        /// Which entry of the comparison to hang off this row, using
        /// helpers/history.py's own metric keys. A row summarising several
        /// numbers at once — the DNS row counts resolvers — has none, and
        /// gets no chip rather than a chip about one of them.
        let metricKey: String?
    }

    private var rows: [Row] {
        let s = snapshot
        func health(_ rules: [String]) -> Health {
            let hits = s.diagnosis.filter { d in d.rule.map(rules.contains) ?? false }
            if hits.contains(where: { $0.severity == "critical" }) { return .critical }
            if hits.contains(where: { $0.severity == "warn" }) { return .warning }
            return .healthy
        }

        var out: [Row] = []
        out.append(Row(label: "Router",
                       value: format(s.gateway.rttAvgMs, "%.1f ms", loss: s.gateway.lossPct),
                       health: health(["G1", "G2", "G3", "DI-1"]),
                       metricKey: "gateway_rtt_ms"))
        out.append(Row(label: "Internet",
                       value: format(s.internetLatency.rttAvgMs, "%.0f ms",
                                     loss: s.internetLatency.lossPct),
                       health: health(["L1", "L2", "P1", "P2", "N1", "N1b"]),
                       metricKey: "inet_rtt_ms"))
        out.append(Row(label: "Name lookups (DNS)",
                       value: s.dns.isEmpty ? "not measured"
                            : "\(s.dns.filter(\.ok).count) of \(s.dns.count) resolvers OK",
                       health: health(["D1", "DH-2"]),
                       metricKey: nil))
        if let wifi = s.wifi {
            out.append(Row(label: "Wi-Fi signal",
                           value: wifi.rssi.map { "\($0) dBm" } ?? "needs sudo to measure",
                           health: health(["W1", "W2", "WS-1", "WD-1"]),
                           metricKey: "wifi_rssi_dbm"))
        }
        out.append(Row(label: "Under load",
                       value: s.bufferbloat.gwGrade.map { grade in
                            s.bufferbloat.gwDeltaMs.map { String(format: "grade %@ (+%.0f ms)", grade, $0) } ?? "grade \(grade)"
                       } ?? "not measured",
                       health: health(["B1", "B2"]),
                       metricKey: "bufferbloat_gw_ms"))
        out.append(Row(label: "Packet size (MTU)",
                       value: s.mtu.effective.map { "\($0) bytes" } ?? "not measured",
                       health: health(["M1"]),
                       metricKey: "mtu_effective"))
        if let speed = s.speedtest {
            out.append(Row(label: "Speed",
                           value: [speed.downMbps.map { String(format: "%.0f Mbps down", $0) },
                                   speed.upMbps.map { String(format: "%.0f up", $0) }]
                                .compactMap { $0 }.joined(separator: " · "),
                           health: health(["BL-1"]),
                           metricKey: "speed_down_mbps"))
        }
        out.append(Row(label: "Clock",
                       value: s.ntp.driftSeconds.map { String(format: "%+.2f s off", $0) } ?? "not measured",
                       health: health(["NT-1"]),
                       metricKey: "ntp_drift_s"))
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

    // MARK: - Comparison

    /// How this run's number sits against the rest of this network's
    /// history, in the CLI's words.
    ///
    /// `summary` is printed exactly as it arrived. `verdict` picks a
    /// colour and does nothing else — the moment this view starts deciding
    /// which side of a percentile a value falls on, the cutoff has left
    /// lib/thresholds.sh.
    @ViewBuilder
    private func comparisonChip(_ row: Row) -> some View {
        if let key = row.metricKey,
           let metric = comparison?.metrics[key],
           !metric.summary.isEmpty {
            Text(metric.summary)
                .font(.caption)
                .foregroundStyle(metric.verdict.tint)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 320, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnoses

    private var diagnoses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What we found").font(.headline)
            if snapshot.diagnosis.isEmpty {
                Label("Nothing obviously wrong — your network looks healthy.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(snapshot.diagnosis) { d in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: d.health.symbol)
                        .foregroundStyle(d.health.tint)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        // Verbatim. The CLI already writes this for a
                        // non-technical reader; rewording it here would be
                        // the app inventing a second opinion.
                        Text(d.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        if showRuleIDs, let rule = d.rule {
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
}

extension RunDetail.Verdict {
    /// Colour only, and deliberately not the diagnosis palette. "Worse than
    /// usual for this network" is a statement about a distribution, not a
    /// fault — a run can sit in the slow tail with nothing wrong with it —
    /// so it stops at orange and never reaches the red that means the CLI
    /// found a problem.
    var tint: Color {
        switch self {
        case .best, .better:   return .green
        case .worst, .worse:   return .orange
        case .typical:         return .secondary
        case .insufficientData, .notMeasured, .unknown: return .secondary
        }
    }
}
