import SwiftUI
import Charts

/// Charts over the whole run store.
///
/// The design constraint that shapes every decision here: **sparse series
/// are the normal case, not an edge case.** In the store this was written
/// against, `gateway.rtt_avg_ms` has 1,959 samples, `bufferbloat.gw_delta_ms`
/// has 38, `wifi.rssi` has 1, and `speedtest.down_mbps` has none at all.
///
/// So every metric shows its sample count, and a metric with no samples in
/// the selected window renders an explicit "no data" panel rather than an
/// empty axis. An empty axis is indistinguishable from a flat line at
/// zero — which, for a download-speed chart, reads as two months of a dead
/// connection.
struct HistoryView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator

    // Gateway RTT and incident count are the defaults because they are the
    // only two series with real depth here. Picking a prettier default that
    // happened to be empty would make the feature look broken on first open.
    @State private var metricKey = "gateway_rtt_ms"
    @State private var window = HistoryWindow.all
    @State private var networkID: String?

    private var store: HistoryStore { coordinator.history }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metricChart
                    incidentChart
                    coverageNote
                }
                .padding(16)
            }
        }
        .task { if store.document.runs.isEmpty { await store.load() } }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Picker("Metric", selection: $metricKey) {
                ForEach(store.document.metrics) { m in
                    // The sample count is in the picker itself, so choosing
                    // an empty metric is an informed choice rather than a
                    // dead end the user has to discover by selecting it.
                    Text("\(m.label) (\(m.samples))").tag(m.key)
                }
            }
            .frame(maxWidth: 260)

            Picker("Window", selection: $window) {
                ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 160)

            Picker("Network", selection: $networkID) {
                Text("All networks").tag(String?.none)
                ForEach(store.mergedNetworks) { net in
                    Text(store.displayName(for: net.id)).tag(String?.some(net.id))
                }
            }
            .frame(maxWidth: 240)

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload history")
            }
        }
        .padding(12)
    }

    // MARK: - Metric chart

    @ViewBuilder
    private var metricChart: some View {
        let descriptor = store.metric(metricKey)
        let points = store.series(metric: metricKey, networkID: networkID, window: window)
        let count = points.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // The unit belongs on the metric's name — "Gateway RTT
                // (ms) · 2027 samples" — not on the sample count, where
                // "(ms)" reads as the unit of "samples".
                Text(chartTitle).font(.headline)
                Text(sampleLabel(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let descriptor, count > 0 {
                    Text(descriptor.higherIsBetter ? "higher is better" : "lower is better")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if count == 0 {
                noData(descriptor)
            } else {
                Chart(points, id: \.0) { point in
                    LineMark(x: .value("When", point.0),
                             y: .value(descriptor?.label ?? "", point.1))
                        .interpolationMethod(.monotone)
                    // Points as well as a line: with 38 samples spread over
                    // two months, a line alone implies a continuous
                    // measurement that was never taken.
                    PointMark(x: .value("When", point.0),
                              y: .value(descriptor?.label ?? "", point.1))
                        .symbolSize(count > 200 ? 4 : 18)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 220)
            }
        }
    }

    /// The explicit empty state. Says which metric has no data, in this
    /// window, and — where it is knowable — why.
    private func noData(_ descriptor: HistoryDocument.MetricDescriptor?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No data for this metric in this window",
                  systemImage: "chart.line.downtrend.xyaxis")
                .font(.callout)
            if let descriptor {
                Text(descriptor.samples == 0
                     ? "No run in your history has ever recorded \(descriptor.label.lowercased()). \(hint(for: descriptor.key))"
                     : "\(descriptor.samples) run\(descriptor.samples == 1 ? "" : "s") elsewhere in your history recorded it — try a longer window or a different network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    /// Why a metric is empty is usually a fact about how netdiag is being
    /// run, and saying so turns a dead chart into an instruction. Since a
    /// full check became reachable from Home and the menu bar, the
    /// instruction is a button rather than a terminal — except for RSSI,
    /// which still genuinely needs a privileged run.
    private func hint(for key: String) -> String {
        switch key {
        case "speed_down_mbps", "speed_up_mbps":
            return "Speed is only measured by a full check. Press \"Full check\" on Home, or join a new network — netdiag runs one automatically the first time."
        case "wifi_rssi_dbm", "wifi_snr_db":
            return "Signal strength needs sudo: run `sudo netdiag` in a terminal to record it."
        case "bufferbloat_gw_ms", "bufferbloat_inet_ms":
            return "Latency under load is only measured by a full check, and is skipped entirely while a connection is already failing."
        case "mtu_effective":
            return "Path MTU is only measured by a full check — the quick check and the background watcher both skip it."
        case "inet_rtt_ms", "inet_loss_pct":
            return "The internet loss probe is skipped by the quick check that the background watcher runs."
        default:
            return "It may be skipped by the check mode you normally run."
        }
    }

    private var chartTitle: String {
        let label = store.metric(metricKey)?.label ?? metricKey
        guard let unit = store.metric(metricKey)?.unit, !unit.isEmpty else { return label }
        return "\(label) (\(unit))"
    }

    private func sampleLabel(_ count: Int) -> String {
        switch count {
        case 0:  return "no samples"
        case 1:  return "1 sample"
        default: return "\(count) samples"
        }
    }

    // MARK: - Incidents

    /// Runs per day, split by the worst severity each one found. The second
    /// series with real depth, and the one that answers "is this getting
    /// worse?" without needing any single metric to be dense.
    private var incidentChart: some View {
        let runs = store.runs(networkID: networkID, window: window)
        let buckets = bucketByDay(runs)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Checks and problems found").font(.headline)
                Text(sampleLabel(runs.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if buckets.isEmpty {
                Text("No checks in this window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    .padding(14)
                    .cardStyle()
            } else {
                Chart(buckets, id: \.key) { bucket in
                    ForEach(["critical", "warn", "ok"], id: \.self) { severity in
                        BarMark(x: .value("Day", bucket.day, unit: .day),
                                y: .value("Checks", bucket.counts[severity] ?? 0))
                            .foregroundStyle(by: .value("Result", severity))
                    }
                }
                .chartForegroundStyleScale([
                    "critical": Color.red, "warn": Color.yellow, "ok": Color.green,
                ])
                // Leading, matching the metric chart above — one chart
                // reading from the left and the next from the right reads
                // as two different apps stacked.
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
            }
        }
    }

    private struct DayBucket {
        let key: String
        let day: Date
        var counts: [String: Int]
    }

    private func bucketByDay(_ runs: [HistoryDocument.Run]) -> [DayBucket] {
        var out: [String: DayBucket] = [:]
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for run in runs {
            let day = calendar.startOfDay(for: run.date)
            let key = formatter.string(from: day)
            var bucket = out[key] ?? DayBucket(key: key, day: day, counts: [:])
            let severity = run.severity == "info" ? "ok" : run.severity
            bucket.counts[severity, default: 0] += 1
            out[key] = bucket
        }
        return out.values.sorted { $0.day < $1.day }
    }

    // MARK: - Coverage

    /// What the history actually contains, stated plainly. A chart is only
    /// as honest as the reader's understanding of its gaps, and this store
    /// has a big one — 1,915 runs on one day, then two months of nothing.
    private var coverageNote: some View {
        let counts = store.document.counts
        return VStack(alignment: .leading, spacing: 4) {
            Text("About this history").font(.headline)
            // A load failure would otherwise render as "0 runs across 0
            // network(s)" — indistinguishable from a genuinely empty
            // store, with the actionable message (a too-old CLI names the
            // fix) swallowed. This is the only surface that reads
            // `HistoryStore.lastError`.
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(counts.runs) run\(counts.runs == 1 ? "" : "s") across \(counts.networks) network\(counts.networks == 1 ? "" : "s"), read from ~/net-diag/baseline.jsonl and its archive.")
                .font(.caption).foregroundStyle(.secondary)
            if counts.redactedDropped > 0 {
                Text("\(counts.redactedDropped) run\(counts.redactedDropped == 1 ? " was" : "s were") skipped: they were recorded with --redact, so their network identity was masked and they can't be attributed to any network.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if counts.duplicatesDropped > 0 {
                Text("\(counts.duplicatesDropped) duplicate record\(counts.duplicatesDropped == 1 ? " was" : "s were") merged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !coordinator.watcher.isInstalled {
                Text("Turn on background checks in Settings to record a run every 15 minutes — history gets much more useful with them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
