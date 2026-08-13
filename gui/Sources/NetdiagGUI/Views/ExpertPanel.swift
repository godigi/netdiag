import SwiftUI
import Charts

/// Layer four of four: raw measurements, hop tables, live sparklines, and
/// the JSON exactly as the CLI emitted it.
///
/// This is a disclosure, not a mode. Nothing here is hidden behind a
/// "technical user" switch chosen at first launch — an expert opens it once
/// and it stays open, and a non-technical user who gets curious can look
/// without declaring anything about themselves.
struct ExpertPanel: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    let run: RunResult
    @State private var showRawJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            liveSparklines
            measurements
            if !run.snapshot.dns.isEmpty { dnsTable }
            if !run.snapshot.tcpReach.isEmpty { tcpTable }
            if !run.snapshot.traceroute.hops.isEmpty { hopTable }
            if !run.snapshot.mtr.hops.isEmpty { perHopTable }
            timings
            rawJSON
        }
        .font(.callout)
    }

    // MARK: - Live sparklines

    /// The last hour of monitor samples. Distinct from the Trends section,
    /// which charts stored runs: this is the live stream, at the cadence
    /// the monitor is actually running, and it is the only place the
    /// between-scans data is visible at all.
    private var liveSparklines: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live monitor").font(.headline)
                Spacer()
                Text(cadenceLabel).font(.caption).foregroundStyle(.secondary)
            }
            let samples = coordinator.monitor.recent
            if samples.count < 2 {
                Text("Collecting samples…").font(.caption).foregroundStyle(.secondary)
            } else {
                // Through MonitorSeries so a pause reads as a break rather
                // than as a straight line between the last sample before it
                // and the first one after. The Live section draws the same
                // data full size, with the gaps shaded and named.
                sparkline("Gateway RTT (ms)",
                          MonitorSeries.build(samples, tier: "fast") { $0.gateway.rttAvgMs })
                sparkline("Gateway loss (%)",
                          MonitorSeries.build(samples, tier: "fast") { $0.gateway.lossPct })
            }
        }
    }

    private var cadenceLabel: String {
        guard let sample = coordinator.monitor.latest else { return "" }
        let cadence = sample.status.cadenceS.map { "every \($0)s" } ?? ""
        return sample.status.degraded ? "\(cadence) · degraded" : cadence
    }

    @ViewBuilder
    private func sparkline(_ title: String, _ series: MonitorSeries.Result) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if series.isEmpty {
                Text("no data").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Chart {
                    ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment) { point in
                            LineMark(x: .value("Time", point.date),
                                     y: .value(title, point.value),
                                     series: .value("segment", index))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 48)
            }
        }
    }

    // MARK: - Measurements

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measurements").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                ForEach(measurementRows, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).textSelection(.enabled)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
        }
    }

    /// `nil` renders as "null (not measured)" and never as 0 — the same
    /// distinction docs/JSON-SCHEMA.md is built on. Someone reading this
    /// panel is reading it precisely to tell the two apart.
    private var measurementRows: [(String, String)] {
        let s = run.snapshot
        func v(_ x: Double?, _ unit: String, _ fmt: String = "%.2f") -> String {
            x.map { String(format: fmt, $0) + " " + unit } ?? "null (not measured)"
        }
        func i(_ x: Int?, _ unit: String) -> String {
            x.map { "\($0) \(unit)" } ?? "null (not measured)"
        }
        var rows: [(String, String)] = [
            ("interface", "\(s.interfaceInfo.name ?? "?") (\(s.interfaceInfo.type ?? "?"))"),
            ("local IP", s.interfaceInfo.ip ?? "null"),
            ("gateway", s.interfaceInfo.gateway ?? "null"),
            ("gateway MAC", s.interfaceInfo.gatewayMAC ?? "null"),
            ("network.id", s.network.id ?? "null"),
            ("gateway RTT", v(s.gateway.rttAvgMs, "ms")),
            ("gateway jitter", v(s.gateway.rttJitterMs, "ms")),
            ("gateway loss", v(s.gateway.lossPct, "%", "%.1f")),
            ("internet RTT (\(s.internetLatency.target ?? "?"))", v(s.internetLatency.rttAvgMs, "ms")),
            ("internet loss (\(s.internetLatency.target ?? "?"))", v(s.internetLatency.lossPct, "%", "%.1f")),
            ("internet loss (\(s.internetLatency.targetAlt ?? "?"))", v(s.internetLatency.lossPctAlt, "%", "%.1f")),
            ("public IP", s.publicInfo.ip ?? "null"),
            ("ASN / ISP", "\(s.publicInfo.asn ?? "?") \(s.publicInfo.isp ?? "")"),
            ("country", "\(s.publicInfo.country ?? "?") (\(s.publicInfo.countryISO ?? "??"))"),
            ("path MTU", i(s.mtu.effective, "bytes")),
            ("bufferbloat Δ gateway", v(s.bufferbloat.gwDeltaMs, "ms")),
            ("bufferbloat grade", s.bufferbloat.gwGrade ?? "null"),
            ("clock drift", v(s.ntp.driftSeconds, "s", "%+.3f")),
            ("IPv6 available", s.ipv6.available ? "yes" : "no"),
        ]
        if let w = s.wifi {
            rows += [
                ("SSID / BSSID", "\(w.ssid ?? "null") / \(w.bssid ?? "null")"),
                ("RSSI / noise / SNR",
                 "\(w.rssi.map(String.init) ?? "null") / \(w.noise.map(String.init) ?? "null") / \(w.snr.map(String.init) ?? "null") dB"),
                ("channel / PHY", "\(w.channel ?? "null") / \(w.phy ?? "null")"),
                ("tx rate", w.txRate ?? "null"),
            ]
        }
        if let d = s.dhcp.timeRemainingS {
            rows.append(("DHCP lease remaining", "\(d / 60) min"))
        }
        if !s.duplicateIPs.isEmpty {
            rows.append(("duplicate IPs", s.duplicateIPs.joined(separator: ", ")))
        }
        return rows
    }

    // MARK: - Tables

    private var dnsTable: some View {
        table("DNS", rows: run.snapshot.dns.map { d in
            (d.ok ? "checkmark" : "xmark",
             "\(d.resolver ?? "?") → \(d.name ?? "?")",
             d.answer ?? "no answer")
        })
    }

    private var tcpTable: some View {
        table("TCP reach", rows: run.snapshot.tcpReach.map { t in
            (t.ok ? "checkmark" : "xmark",
             "\(t.host ?? "?"):\(t.port ?? 0)",
             t.elapsedMs.map { String(format: "%.0f ms", $0) } ?? "failed")
        })
    }

    private var hopTable: some View {
        table("Traceroute to \(run.snapshot.traceroute.target ?? "?")",
              rows: run.snapshot.traceroute.hops.map { h in
            (h.responded ? "arrow.right" : "questionmark",
             "\(h.n ?? 0). \(h.ip ?? "no reply")",
             h.rttMs.map { String(format: "%.1f ms", $0) } ?? "—")
        })
    }

    private var perHopTable: some View {
        table("Per-hop loss", rows: run.snapshot.mtr.hops.map { h in
            (h.lossPct.map { $0 > 0 } == true ? "exclamationmark" : "checkmark",
             "\(h.n ?? 0). \(h.ip ?? "???")",
             "\(h.lossPct.map { String(format: "%.0f%% loss", $0) } ?? "—") · \(h.avgMs.map { String(format: "%.1f ms", $0) } ?? "—")")
        })
    }

    private func table(_ title: String,
                       rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Image(systemName: row.0).font(.caption2).frame(width: 14)
                        Text(row.1).font(.system(.caption, design: .monospaced))
                        Text(row.2).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var timings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timing").font(.headline)
            let t = run.snapshot.timings
            Text("total \(t.totalS.map { String(format: "%.1f", $0) } ?? "?") s · budget \(t.budgetS.map { String(format: "%.0f", $0) } ?? "?") s\(t.overBudget ? " · over budget" : "")")
                .font(.caption)
                .foregroundStyle(t.overBudget ? .orange : .secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
                ForEach(t.phases.sorted { $0.value > $1.value }, id: \.key) { phase, secs in
                    GridRow {
                        Text(phase).font(.system(.caption, design: .monospaced))
                        Text(String(format: "%.2f s", secs)).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Raw JSON

    /// The bytes the CLI actually emitted, not a re-encode of this app's
    /// partial model. Someone opening this wants to check what netdiag
    /// said, and a round-trip through a Swift struct that models 40 of 60
    /// fields would quietly answer a different question.
    private var rawJSON: some View {
        DisclosureGroup(isExpanded: $showRawJSON) {
            ScrollView([.horizontal, .vertical]) {
                Text(run.rawJSON)
                    .font(Theme.Font.rawJSONMonospace)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(maxHeight: 320)
            .cardStyle()
        } label: {
            HStack {
                Text("Raw JSON").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.rawJSON, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}
