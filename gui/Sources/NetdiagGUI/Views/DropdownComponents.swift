import SwiftUI
import AppKit

/// Building blocks for the dropdown's fixed sections. Dumb views over
/// CLI-sourced values: anything resembling a verdict arrived here as a
/// rule ID, a severity, or CLI prose.

// MARK: - Instrument grid cell

struct InstrumentCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let unit {
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Location cell (flag; hover reveals IP; click copies)

struct LocationCell: View {
    let countryISO: String?
    let publicIP: String?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 2) {
            Text("Location")
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(Flag.emoji(forISOCode: countryISO) ?? "🌐")
                .font(.system(size: 15))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let publicIP else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(publicIP, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .overlay(alignment: .top) {
            if hovering, let publicIP {
                Text(copied ? "Copied" : "\(publicIP) · click to copy")
                    .font(Theme.Font.compactMonospace)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .offset(y: -26)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .help(publicIP == nil ? "Location unknown" : "")
    }
}

// MARK: - Heartbeat strip

/// A thin live sparkline of fast-tier gateway RTT. Its job is to prove
/// monitoring is alive, not to be read precisely — Live has the real
/// charts.
struct HeartbeatStrip: View {
    let samples: [MonitorSample]
    var flatlined = false

    private var points: [Double] {
        samples.suffix(60).compactMap { $0.gateway.rttAvgMs }
    }

    var body: some View {
        Canvas { context, size in
            let values = flatlined ? [] : points
            guard values.count > 1 else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(.secondary.opacity(0.4)),
                               lineWidth: 1)
                return
            }
            let maxV = max(values.max() ?? 1, 1)
            let minV = values.min() ?? 0
            let span = max(maxV - minV, 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height - size.height *
                    CGFloat((v - minV) / span) * 0.8 - size.height * 0.1
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.green.opacity(0.7)),
                           lineWidth: 1)
        }
        .frame(height: 12)
        .background(.quaternary.opacity(Theme.cardOpacity),
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Timeline band

struct TimelineBand: View {
    let events: [NetworkEvent]
    let hours: Double
    var now: Date = .now

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.green.opacity(0.15))
                    ForEach(events) { event in
                        let age = now.timeIntervalSince(event.date)
                        let x = geo.size.width *
                            CGFloat(1 - age / (hours * 3600))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(EventStyle.tint(for: event.kind))
                            .frame(width: 3)
                            .offset(x: max(0, min(x, geo.size.width - 3)))
                    }
                }
            }
            .frame(height: 20)
            HStack {
                Text("24 h ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Event row

struct EventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EventStyle.symbol(for: event.kind))
                .font(.system(size: 10))
                .foregroundStyle(EventStyle.tint(for: event.kind))
                .frame(width: 18, height: 18)
                .background(EventStyle.tint(for: event.kind).opacity(0.12),
                            in: Circle())
            Text(event.summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(RelativeTime.string(from: event.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
    }
}

// MARK: - Kind → presentation mapping (identity, not judgment)

enum EventStyle {
    static func symbol(for kind: String) -> String {
        switch kind {
        case "vpn-connected", "vpn-disconnected", "vpn-name-changed":
            return "lock.fill"
        case "public-ip-changed", "country-changed", "isp-changed":
            return "globe"
        case "wifi-network-changed", "wifi-roamed":
            return "wifi"
        case "interface-changed":
            return "cable.connector"
        case "rule-fired", "alert":
            return "exclamationmark.triangle.fill"
        case "rule-cleared":
            return "checkmark.circle.fill"
        default:
            return "circle.fill"
        }
    }

    static func tint(for kind: String) -> Color {
        switch kind {
        case "rule-fired", "alert": return .red
        case "rule-cleared": return .green
        case "vpn-disconnected": return .orange
        default: return .yellow
        }
    }
}
