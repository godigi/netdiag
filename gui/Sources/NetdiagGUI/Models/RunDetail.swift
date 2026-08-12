import Foundation

/// The output of `netdiag --show=<id>`: one stored run, the plain facts
/// about where it sits in that network's history, and the CLI's comparison
/// of it against every other run on the same network.
///
/// The split between `context` and `comparison` is the whole design.
/// `context` is arithmetic — how many runs, which position, first and last
/// seen — and carries no judgement. `comparison` is judgement, made in
/// helpers/history.py against the percentile cutoffs in lib/thresholds.sh,
/// where every other cutoff in this project lives. This app renders
/// `summary` verbatim and uses `verdict` for a colour and nothing else: no
/// number in this file is compared to another, and no sentence about a
/// network is composed in it.
struct RunDetail: Decodable, Sendable {
    var schema: Int = 1
    var version: String?
    var id: String = ""
    var run: RunSnapshot
    var context: Context = .init()
    var comparison: Comparison = .init()

    /// The bytes `--show` actually printed. Not part of the JSON — the
    /// runner attaches them — and kept for the same reason the live path
    /// keeps `RunResult.rawJSON`: someone opening the expert layer wants to
    /// check what netdiag said, and a re-encode of this app's partial model
    /// would quietly answer a different question.
    var rawJSON: String = ""

    enum CodingKeys: String, CodingKey {
        case schema, version, id, run, context, comparison
    }

    struct Context: Decodable, Sendable {
        var networkID: String?
        /// Every run on this network. A metric's own `n` counts how many of
        /// them recorded *that metric*, and the two differ by a lot — 1,915
        /// checks against 38 bufferbloat readings. Showing one number
        /// without the other misrepresents both.
        var runsOnNetwork: Int = 0
        /// This run's 1-based chronological index among them, oldest first.
        var position: Int = 0
        var firstSeen: String?
        var lastSeen: String?

        enum CodingKeys: String, CodingKey {
            case position
            case networkID = "network_id"
            case runsOnNetwork = "runs_on_network"
            case firstSeen = "first_seen"
            case lastSeen = "last_seen"
        }
    }

    struct Comparison: Decodable, Sendable {
        /// Keyed by the metric keys helpers/history.py's `METRICS` table
        /// already defines — the same keys `--history` reports samples
        /// against, so the report card and the charts name one thing once.
        var metrics: [String: Metric] = [:]

        enum CodingKeys: String, CodingKey { case metrics }
    }

    struct Metric: Decodable, Sendable {
        /// The CLI's copy of this run's number. The report card renders the
        /// snapshot's own value, so this exists to keep the object
        /// self-describing rather than to be displayed — and it is `nil`,
        /// never 0, when the run did not record the metric.
        var value: Double?
        var median: Double?
        var p10: Double?
        var p90: Double?
        var percentile: Double?
        /// How many runs on this network recorded this metric. Below the
        /// CLI's minimum the verdict is `insufficientData`, decided there.
        var n: Int = 0
        var direction: String = ""
        var verdict: Verdict = .unknown
        /// Rendered verbatim, and the only prose in this app about whether
        /// a number is good. Writing one here would be the app forming a
        /// second opinion about a network the CLI has already judged.
        var summary: String = ""

        enum CodingKeys: String, CodingKey {
            case value, median, p10, p90, percentile, n, direction, verdict, summary
        }
    }

    /// A closed set, so the UI can tint without parsing prose.
    ///
    /// `notMeasured` is deliberately distinct from a value of zero — the
    /// same line docs/JSON-SCHEMA.md draws, and the one whose absence
    /// produced false diagnoses in earlier versions of this project.
    enum Verdict: String, Sendable {
        case typical, better, worse, best, worst
        case insufficientData = "insufficient_data"
        case notMeasured = "not_measured"
        /// A verdict this build does not recognise. The set is closed
        /// today; a future CLI adding to it must not stop a check from
        /// opening, and an unknown verdict gets no colour rather than a
        /// wrong one.
        case unknown
    }

    /// ExpertPanel renders a `RunResult`, which carries two things a stored
    /// record cannot: the process's exit status and its wall-clock span.
    /// Neither is read by that panel — it takes its timings from the JSON's
    /// own `timings` block — so both are filled from the record itself
    /// rather than invented.
    var asRunResult: RunResult {
        RunResult(snapshot: run, rawJSON: rawJSON, exitCode: 0,
                  startedAt: run.date, finishedAt: run.date)
    }
}

// MARK: - Lenient decoding
//
// The same discipline as RunSnapshot, for a different reason: `--show` is
// a new surface and will grow. A key this build has not heard of, or one
// the CLI stops emitting, must leave the check openable. `run` is the
// exception — it is the payload, and a detail without one is not a detail.

extension RunDetail {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema, 1)
        version = c.lenient(.version)
        id = c.lenient(.id, "")
        run = try c.decode(RunSnapshot.self, forKey: .run)
        context = c.lenient(.context, .init())
        comparison = c.lenient(.comparison, .init())
    }
}

extension RunDetail.Context {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networkID = c.lenient(.networkID)
        runsOnNetwork = c.lenient(.runsOnNetwork, 0)
        position = c.lenient(.position, 0)
        firstSeen = c.lenient(.firstSeen)
        lastSeen = c.lenient(.lastSeen)
    }
}

extension RunDetail.Comparison {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = c.lenient(.metrics, [:])
    }
}

extension RunDetail.Metric {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.lenient(.value)
        median = c.lenient(.median)
        p10 = c.lenient(.p10)
        p90 = c.lenient(.p90)
        percentile = c.lenient(.percentile)
        n = c.lenient(.n, 0)
        direction = c.lenient(.direction, "")
        // An absent verdict is not a typical one. Falling back to `typical`
        // would paint a missing judgement as a delivered one.
        verdict = RunDetail.Verdict(rawValue: c.lenient(.verdict, "")) ?? .unknown
        summary = c.lenient(.summary, "")
    }
}
