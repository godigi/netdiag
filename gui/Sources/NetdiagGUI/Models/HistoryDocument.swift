import Foundation

/// The output of `netdiag --history`.
///
/// Every hard question about this data — which runs belong to which
/// network, which groups were inferred rather than recorded, which
/// [redacted] records to drop — is answered in helpers/history.py before it
/// reaches Swift. That is deliberate: identity logic exists once, in the
/// same language as the CLI that writes the records, and the app decodes a
/// result rather than re-deriving one.
struct HistoryDocument: Decodable, Sendable {
    var schema: Int = 1
    var counts: Counts = .init()
    var metrics: [MetricDescriptor] = []
    var networks: [Network] = []
    var runs: [Run] = []

    static let empty = HistoryDocument()

    struct Counts: Decodable, Sendable {
        var recordsRead: Int = 0
        var duplicatesDropped: Int = 0
        var redactedDropped: Int = 0
        var unparseableDropped: Int = 0
        var runs: Int = 0
        var networks: Int = 0

        enum CodingKeys: String, CodingKey {
            case runs, networks
            case recordsRead = "records_read"
            case duplicatesDropped = "duplicates_dropped"
            case redactedDropped = "redacted_dropped"
            case unparseableDropped = "unparseable_dropped"
        }
    }

    /// Label, unit and direction all come from the CLI. A chart needs to
    /// know whether up is good to colour a trend, and that is a property of
    /// the metric, not of the view.
    struct MetricDescriptor: Decodable, Sendable, Identifiable, Hashable {
        var key: String = ""
        var label: String = ""
        var unit: String = ""
        var direction: String = "lower_is_better"
        /// How many runs in the whole store carry this metric. Mandatory
        /// on screen: `wifi.rssi` is populated in 1 of 1,926 legacy records
        /// here, and a chart that plots it without saying so presents a
        /// single reading as a trend.
        var samples: Int = 0
        var id: String { key }
        var higherIsBetter: Bool { direction == "higher_is_better" }
    }

    struct Network: Decodable, Sendable, Identifiable, Hashable {
        var id: String = ""
        var label: String = ""
        /// True when the grouping was inferred — backfilled from a record
        /// that predates network identity, or bridged into another group
        /// by the gateway+ISP heuristic. Surfaced in NetworksView so the
        /// UI stays honest about what it knows.
        var synthesized: Bool = false
        var bridgedFrom: [String] = []
        var firstSeen: String?
        var lastSeen: String?
        var runCount: Int = 0
        var gateways: [String] = []
        var isps: [String] = []
        var ssids: [String] = []
        var metricSamples: [String: Int] = [:]
        var severityCounts: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case id, label, synthesized, gateways, isps, ssids
            case bridgedFrom = "bridged_from"
            case firstSeen = "first_seen"
            case lastSeen = "last_seen"
            case runCount = "run_count"
            case metricSamples = "metric_samples"
            case severityCounts = "severity_counts"
        }

        var firstSeenDate: Date? { ISO8601DateFormatter().date(from: firstSeen ?? "") }
        var lastSeenDate: Date? { ISO8601DateFormatter().date(from: lastSeen ?? "") }

        var incidentCount: Int {
            (severityCounts["warn"] ?? 0) + (severityCounts["critical"] ?? 0)
        }

        var incidentRate: Double {
            runCount > 0 ? Double(incidentCount) / Double(runCount) : 0
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (a: Network, b: Network) -> Bool { a.id == b.id }
    }

    struct Run: Decodable, Sendable, Identifiable {
        var ts: String?
        var networkID: String = ""
        var version: String?
        var severity: String = "ok"
        var diagnosisCount: Int = 0
        var rules: [String] = []
        var rootCause: String?
        /// Absent keys mean "not measured in that run", never zero. A chart
        /// must skip them rather than draw a cliff that never happened.
        var metrics: [String: Double] = [:]

        enum CodingKeys: String, CodingKey {
            case ts, version, severity, rules, metrics
            case networkID = "network_id"
            case diagnosisCount = "diagnosis_count"
            case rootCause = "root_cause"
        }

        var id: String { "\(ts ?? "")-\(networkID)" }
        var date: Date { ISO8601DateFormatter().date(from: ts ?? "") ?? .distantPast }

        var health: Health {
            switch severity {
            case "critical": return .critical
            case "warn":     return .warning
            default:         return .healthy
            }
        }
    }
}

/// A window over the history, for the chart's time picker.
enum HistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case day = "24 hours"
    case week = "7 days"
    case month = "30 days"
    case all = "All time"

    var id: String { rawValue }

    var cutoff: Date? {
        switch self {
        case .day:   return Date().addingTimeInterval(-86_400)
        case .week:  return Date().addingTimeInterval(-7 * 86_400)
        case .month: return Date().addingTimeInterval(-30 * 86_400)
        case .all:   return nil
        }
    }
}
