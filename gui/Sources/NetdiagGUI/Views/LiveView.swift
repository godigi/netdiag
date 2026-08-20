import SwiftUI
import Charts

/// The last hour of the monitor stream, drawn.
///
/// This is the only section that needs no CLI run at all:
/// `MonitorStream.recent` has been holding an hour of samples since the
/// stream existed and nothing drew them. The Trends section charts *stored
/// runs* — sparse, minutes to days apart; this charts the live stream at
/// whatever cadence it is actually running.
///
/// The rule that shapes it: **gaps are drawn as gaps.** See
/// `MonitorSeries` for why, and for how a gap is told apart from a slow
/// cadence without hardcoding either.
struct LiveView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings

    /// As far back as `recent` is bounded to hold at the default cadence.
    private static let window: TimeInterval = 3600

    private var monitor: MonitorStream { coordinator.monitor }

    private var samples: [MonitorSample] {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return monitor.recent.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stateBanner
                currentValues
                let samples = samples
                chart(title: "Router round-trip",
                      subtitle: "Gateway ping, every cycle of the fast tier.",
                      series: MonitorSeries.build(samples, tier: "fast") {
                          $0.gateway.rttAvgMs
                      },
                      absent: "No router round-trip has been measured in the last hour.",
                      unit: "ms")
                chart(title: "Internet round-trip",
                      subtitle: internetSubtitle,
                      series: MonitorSeries.build(samples, tier: "medium",
                                                  value: Self.internetMs),
                      absent: "No internet round-trip has been measured in the last hour.",
                      unit: "ms")
                chart(title: "Router packet loss",
                      subtitle: "Share of the gateway ping's packets that got no reply.",
                      series: MonitorSeries.build(samples, tier: "fast") {
                          $0.gateway.lossPct
                      },
                      absent: "No packet-loss measurement in the last hour.",
                      unit: "%")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - State

    /// Monitoring off, paused, or bursting. Never a blank chart with no
    /// explanation: an empty chart and a stopped monitor look identical,
    /// and only one of them is the user's problem to fix.
    @ViewBuilder
    private var stateBanner: some View {
        if !appSettings.monitoringEnabled {
            banner("Monitoring is off",
                   "Nothing is being sampled, so this chart will not move. Resume monitoring from the menu-bar icon.",
                   systemImage: "pause.circle")
        } else if let reason = monitor.pauseReason {
            // Verbatim from the monitor's own pause bookkeeping, which is
            // reference-counted by reason — so this names every hold, not
            // just the most recent one.
            banner("Paused — \(reason)",
                   "Samples resume automatically. The stretch this covers is left blank rather than drawn through.",
                   systemImage: "pause.circle")
        } else if let error = monitor.lastError {
            banner("Monitoring stopped", error, systemImage: "exclamationmark.triangle")
        } else if let until = monitor.burstUntil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latency test — sampling every \(appSettings.latencyTestInterval)s")
                        .font(.callout)
                    Text("Back to the usual cadence at \(until.formatted(date: .omitted, time: .standard)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Stop") { coordinator.stopLatencyTest() }
            }
            .padding(12)
            .cardStyle()
        }
    }

    private func banner(_ title: String, _ detail: String,
                        systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle()
    }

    // MARK: - Current values

    private var currentValues: some View {
        HStack(alignment: .top, spacing: 28) {
            value("Router", latestGateway)
            value("Internet", latestInternet)
            value("Sampling", cadenceLabel)
            Spacer(minLength: 0)
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3).monospacedDigit()
        }
    }

    /// "not measured" is a different statement from a number, and it is
    /// never rendered as 0.
    private var latestGateway: String {
        guard let ms = monitor.latest?.gateway.rttAvgMs else { return "not measured" }
        return String(format: "%.0f ms", ms)
    }

    private var latestInternet: String {
        guard let sample = monitor.latest, let ms = Self.internetMs(sample) else {
            return "not measured"
        }
        return String(format: "%.0f ms", ms)
    }

    /// The cadence the stream reports about itself, plus the tier it is on.
    /// "degraded" is the monitor's own word for its faster tier and carries
    /// no verdict of this app's.
    private var cadenceLabel: String {
        guard let status = monitor.latest?.status, let cadence = status.cadenceS else {
            return monitor.isRunning ? "starting…" : "stopped"
        }
        if monitor.isBursting { return "every \(cadence)s · test" }
        return status.degraded ? "every \(cadence)s · degraded" : "every \(cadence)s"
    }

    /// The monitor has no ICMP probe past the gateway; its reading on the
    /// internet is how long a TCP connection to a well-known host takes to
    /// open. The fastest of the targets, because a single slow *host* is a
    /// fact about that host, not about the link.
    private static func internetMs(_ sample: MonitorSample) -> Double? {
        sample.tcp.targets.filter(\.ok).compactMap(\.elapsedMs).min()
    }

    private var internetSubtitle: String {
        let hosts = monitor.latest?.tcp.targets.compactMap(\.host) ?? []
        let named = hosts.isEmpty ? "well-known hosts" : hosts.joined(separator: ", ")
        return "Time to open a TCP connection to \(named). Measured on the medium tier, so it is sparser than the router line."
    }

    // MARK: - Charts

    @ViewBuilder
    private func chart(title: String, subtitle: String,
                       series: MonitorSeries.Result, absent: String,
                       unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(sampleLabel(series.points.count)).font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if series.isEmpty {
                empty(absent)
            } else {
                LiveChart(series: series, unit: unit)

                if !series.gaps.isEmpty {
                    Text(gapNote(series.gaps.count))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "waveform.path.ecg")
                .font(.callout)
            Text(appSettings.monitoringEnabled
                 ? "Samples appear here as the monitor takes them — the first one lands within a cycle."
                 : "Monitoring is off, so nothing is being sampled.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    private func gapNote(_ count: Int) -> String {
        let plural = count == 1 ? "1 gap" : "\(count) gaps"
        return "\(plural) — the monitor stops sampling while a check runs and while your Mac or display sleeps. Nothing was measured in the shaded stretches."
    }

    private func sampleLabel(_ count: Int) -> String {
        switch count {
        case 0:  return "no samples"
        case 1:  return "1 sample"
        default: return "\(count) samples"
        }
    }
}

/// The chart body of `LiveView`'s panels, with a hover readout.
///
/// Extracted from `LiveView.chart(...)` so it can own its own selection
/// state — one `@State` per panel, rather than one shared across three
/// charts that would cross-talk. Hovering (or dragging) anywhere along the
/// x-axis snaps a highlight to the nearest measured point and shows its
/// value and timestamp; moving off the chart clears it. The highlight is a
/// larger white point mark drawn over the accent one, so it reads against
/// any chart background.
struct LiveChart: View {
    let series: MonitorSeries.Result
    let unit: String
    @State private var selectedDate: Date?

    /// Nearest measured point to the cursor's x, or nil when the cursor is
    /// off the chart. O(points) on each move — the window is bounded to one
    /// hour, which is at most a few hundred samples, so the linear scan is
    /// cheaper than maintaining an index would be.
    private var hovered: MonitorSeries.Point? {
        guard let selectedDate else { return nil }
        return series.points.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        })
    }

    var body: some View {
        Chart {
            // Shaded rather than merely blank, because "the line stops
            // here" and "the value went off the top" look alike at a glance.
            ForEach(series.gaps) { gap in
                RectangleMark(xStart: .value("From", gap.start),
                              xEnd: .value("To", gap.end))
                    .foregroundStyle(.quaternary.opacity(0.5))
            }
            // One series per segment, so no line is drawn across a stretch
            // where nothing was measured.
            ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { point in
                    LineMark(x: .value("Time", point.date),
                             y: .value("Value", point.value),
                             series: .value("segment", index))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Time", point.date),
                              y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(segment.count > 120 ? 4 : 14)
                }
            }
            if let hovered {
                PointMark(x: .value("Time", hovered.date),
                          y: .value("Value", hovered.value))
                    .foregroundStyle(.white)
                    .symbolSize(40)
                    .annotation(position: .top, spacing: 4) {
                        HoverLabel(value: hovered.value, unit: unit, date: hovered.date)
                    }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXSelection(value: $selectedDate)
        .frame(height: 180)
    }
}

/// The floating readout above the hovered point: value with unit, and the
/// wall-clock time it was measured. Kept compact so it does not overrun the
/// chart's top margin on the narrow panels.
struct HoverLabel: View {
    let value: Double
    let unit: String
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Text(String(format: "%.0f %@", value, unit))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(date.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }
}