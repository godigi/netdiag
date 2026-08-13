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

    /// One formatter for every timestamp in this document. Constructing
    /// `ISO8601DateFormatter()` per call looks free and is not: a sort of
    /// ~2,000 runs through per-call construction measured 5.3 s on a real
    /// store, against 0.6 ms without it. Sharing one instance here is sound
    /// because every caller — `HistoryStore` and this file's own
    /// `Run.date`, `Network.firstSeenDate`/`lastSeenDate` — runs on
    /// `@MainActor`, not because `ISO8601DateFormatter` is documented safe
    /// for concurrent use from multiple threads (it isn't, explicitly).
    /// `RunSnapshot` and `MonitorSample` still construct their own per call;
    /// that's a different file and out of scope here.
    static let iso = ISO8601DateFormatter()

    struct Counts: Decodable, Sendable {
        var recordsRead: Int = 0
        var duplicatesDropped: Int = 0
        var redactedDropped: Int = 0
        var unparseableDropped: Int = 0
        var runs: Int = 0
        /// Of `runs`, the ones that examined the network rather than
        /// answering one narrow question about it — see
        /// `HistoryDocument.Run.isCheck`. Optional, not defaulted to 0:
        /// this key is new in v0.9.0:T3, and an old CLI omitting it must
        /// read as "unknown", not "zero checks ever ran".
        var checks: Int?
        var networks: Int = 0

        enum CodingKeys: String, CodingKey {
            case runs, checks, networks
            case recordsRead = "records_read"
            case duplicatesDropped = "duplicates_dropped"
            case redactedDropped = "redacted_dropped"
            case unparseableDropped = "unparseable_dropped"
        }
    }

    /// One metric's population summary for one network: the same
    /// `median`/`p10`/`p90` arithmetic `--show`'s `comparison` computes for
    /// a single run, reused rather than re-derived here for a whole
    /// network's worth of samples (helpers/history.py's
    /// `population_stats`). Carries no verdict or direction — this states
    /// what a network's numbers look like, never whether one reading was
    /// good, which stays `--show`'s question alone.
    struct MetricStat: Decodable, Sendable {
        var median: Double?
        var p10: Double?
        var p90: Double?

        enum CodingKeys: String, CodingKey { case median, p10, p90 }
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
        /// This network's `MetricStat` per metric key in `metrics[]` —
        /// `nil` for a metric below `THRESH_COMPARE_MIN_SAMPLES`, and the
        /// whole dictionary `nil` (never empty) when the running CLI
        /// predates `metric_stats` entirely, so the two "no answer" cases
        /// stay distinguishable. `HistoryStore.median(metric:networkID:)`
        /// is the one place this app reads it.
        var metricStats: [String: MetricStat?]?
        var severityCounts: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case id, label, synthesized, gateways, isps, ssids
            case bridgedFrom = "bridged_from"
            case firstSeen = "first_seen"
            case lastSeen = "last_seen"
            case runCount = "run_count"
            case metricSamples = "metric_samples"
            case metricStats = "metric_stats"
            case severityCounts = "severity_counts"
        }

        /// This network's summary for one metric, flattened to a single
        /// optional: `nil` whether the CLI never sent `metric_stats` at
        /// all or sent it with this metric's block null.
        func stat(for metric: String) -> MetricStat? {
            metricStats?[metric] ?? nil
        }

        var firstSeenDate: Date? { HistoryDocument.iso.date(from: firstSeen ?? "") }
        var lastSeenDate: Date? { HistoryDocument.iso.date(from: lastSeen ?? "") }

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
        /// The CLI's handle for this run — `<timestamp>.<8 hex>` — and the
        /// only thing `--show` accepts. `ts` alone will not do:
        /// helpers/history.py dedups on (timestamp, canonical JSON)
        /// precisely because two runs can land in the same second, and when
        /// they do a timestamp names neither of them.
        ///
        /// Optional because the app and the CLI are installed separately
        /// and their versions skew. A netdiag older than the one that
        /// introduced `--show` stamps no id, and a run without one can be
        /// listed but not opened — see RunListView, which says so rather
        /// than offering a row that would fail.
        var runID: String?
        var networkID: String = ""
        var version: String?
        /// How much of the battery this run attempted — the closed set
        /// docs/JSON-SCHEMA.md documents under `run_mode`. `nil` on every
        /// record written before v0.9.0. See `isCheck`, the one predicate
        /// this app derives from it.
        var runMode: String?
        var severity: String = "ok"
        var diagnosisCount: Int = 0
        var rules: [String] = []
        var rootCause: String?
        /// Absent keys mean "not measured in that run", never zero. A chart
        /// must skip them rather than draw a cliff that never happened.
        var metrics: [String: Double] = [:]

        enum CodingKeys: String, CodingKey {
            case ts, version, severity, rules, metrics
            case runID = "id"
            case networkID = "network_id"
            case runMode = "run_mode"
            case diagnosisCount = "diagnosis_count"
            case rootCause = "root_cause"
        }

        /// Identity for SwiftUI, which is not the same question as "what
        /// does `--show` accept". Falls back to the composite this type
        /// used before the CLI stamped ids, so a list built from an older
        /// netdiag still has stable row identity instead of a run of
        /// duplicate empty strings.
        var id: String { runID ?? "\(ts ?? "")-\(networkID)" }
        var date: Date { HistoryDocument.iso.date(from: ts ?? "") ?? .distantPast }

        var health: Health {
            switch severity {
            case "critical": return .critical
            case "warn":     return .warning
            default:         return .healthy
            }
        }

        /// True when this run examined the network rather than answering
        /// one narrow question about it. docs/JSON-SCHEMA.md's `run_mode`
        /// table: "the suffix is the rule rather than a list of the three
        /// [modes] that exist today… a list would go stale the day a
        /// `--dns-only` landed, and it would go stale silently, by counting
        /// the new mode as a full check." `helpers/history.py`'s
        /// `is_check()` applies this identical rule server-side to build
        /// `counts.checks` and `severity_counts`; this is the one place the
        /// GUI re-applies it, per CLAUDE.md's no-diagnostic-logic-in-Swift
        /// rule — it reads a documented naming convention, not the run's
        /// content, so it is data plumbing rather than a judgement call.
        ///
        /// `nil` predates v0.9.0 and counts as a check: those runs were
        /// full or quick ones, and reclassifying them would rewrite months
        /// of a user's own history the moment this shipped.
        var isCheck: Bool {
            guard let runMode else { return true }
            return !runMode.hasSuffix("-only")
        }

        /// The CLI's own sentence where it reached one, else a count.
        /// Shared by `RunListView` and `HomeView`'s "Recent checks" card so
        /// the same run never reads two different ways depending on which
        /// list is showing it.
        ///
        /// Where the CLI reached no conclusion, this counts rather than
        /// invents one: most warning-level runs carry no
        /// `most_likely_root_cause`, and printing "No problems found" next
        /// to their amber dot would be the app contradicting the CLI.
        var headline: String {
            let cause = rootCause?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cause.isEmpty { return cause }
            return diagnosisCount == 0 ? "No problems found" : "\(diagnosisCount) finding(s)"
        }

        /// A presentational relabeling of the closed `run_mode` set
        /// docs/JSON-SCHEMA.md documents — "how much of the battery this
        /// run attempted", not a judgement about the network, so per the
        /// redesign's risk register this is safe to keep in Swift. `nil`
        /// for a record written before v0.9.0 stamped `run_mode` at all:
        /// there is no honest badge to show for those, so none is shown.
        var modeBadge: String? {
            switch runMode {
            case "full":       return "full check"
            case "quick":      return "quick check"
            case "speed-only": return "speed reading"
            case "mtu-only":   return "MTU check"
            case "wifi-only":  return "WiFi scan"
            default:           return nil
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
