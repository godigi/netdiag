import Foundation

/// Lenient model of `netdiag --rules-catalog` — see that schema in
/// docs/JSON-SCHEMA.md, and helpers/rules_catalog.py for what writes it.
///
/// This is the CLI's plain-language layer, and CLAUDE.md draws a hard line
/// around it: "the GUI holds no diagnostic logic." Every word a `RuleChip`
/// or a report-card row shows about a rule — its title, its blurb, which
/// severity it normally carries — comes from here, verbatim. Nothing in
/// this type, or in anything that reads it, composes a sentence about a
/// rule or invents a category for one the catalog doesn't name.
///
/// Additive by the schema's own promise (docs/JSON-SCHEMA.md: "never
/// removes or repurposes" a field), so every property below is optional
/// except `Rule.id` — see that struct's header for how a ruleless catalog
/// entry (an id-less object a future schema bump could in principle emit)
/// is kept out rather than crashing `Identifiable` on an empty string.
struct RulesCatalog: Decodable, Sendable {
    var schema: Int?
    var version: String?
    var rules: [Rule] = []
    /// The glossary sibling array added in schema `2` — see
    /// helpers/rules_catalog.py's module docstring for why it lives here
    /// rather than in a standalone mode. Empty, never a decode failure,
    /// against a CLI old enough to only emit schema `1`.
    var metrics: [Metric] = []

    enum CodingKeys: String, CodingKey { case schema, version, rules, metrics }

    /// One entry from `rules`. `category` and `severity` describe the
    /// *rule*, not a specific incident — a run's own diagnosis carries the
    /// severity that actually applies (`RunSnapshot.Diagnosis.severity`);
    /// this one is the catalog's general answer, e.g. `"varies"` for a
    /// rule like `B1` that grades by magnitude.
    struct Rule: Sendable, Identifiable {
        let id: String
        var title: String?
        var category: String?
        var severity: String?
        var scope: String?
        var blurb: String?
        var doc: String?
    }

    /// One entry from `metrics` — a jargon term the report card shows,
    /// explained in plain English. See `docs/JSON-SCHEMA.md`'s
    /// `--rules-catalog` section for the field meanings.
    struct Metric: Sendable, Identifiable {
        var id: String { key }
        let key: String
        var label: String?
        var help: String?
    }

    /// Rule lookup by id, built once when the catalog decodes rather than
    /// scanned per call — a run's diagnosis list and a report card's rows
    /// both look one up per render.
    private var byID: [String: Rule] = [:]
    /// Metric-glossary lookup by key, same reasoning as `byID`.
    private var metricsByKey: [String: Metric] = [:]

    subscript(id: String) -> Rule? { byID[id] }
    func metric(_ key: String) -> Metric? { metricsByKey[key] }
}

// MARK: - Lenient decoding

extension RulesCatalog {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema)
        version = c.lenient(.version)
        // Every field of a raw entry decodes as optional, `id` included,
        // because `KeyedDecodingContainer.lenient` (see its header) is the
        // one honest way to read a schema that promises only to grow: a
        // `Rule` this build doesn't fully recognise degrades field by
        // field instead of the whole catalog failing to decode. An entry
        // that comes out with no id at all — today unreachable, since
        // `helpers/rules_catalog.py` always writes one — is dropped rather
        // than kept with a fabricated id, since `Rule.id` is what every
        // lookup and every `Identifiable` list keys on.
        let raw = c.lenient(.rules, [RawRule]())
        rules = raw.compactMap { entry in
            guard let id = entry.id, !id.isEmpty else { return nil }
            return Rule(id: id, title: entry.title, category: entry.category,
                        severity: entry.severity, scope: entry.scope,
                        blurb: entry.blurb, doc: entry.doc)
        }
        byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Same degrade-field-by-field discipline as `rules` above. Absent
        // entirely against a CLI whose catalog predates schema `2` —
        // `c.lenient(.metrics, [])` already returns `[]` in that case, no
        // extra branch needed.
        let rawMetrics = c.lenient(.metrics, [RawMetric]())
        metrics = rawMetrics.compactMap { entry in
            guard let key = entry.key, !key.isEmpty else { return nil }
            return Metric(key: key, label: entry.label, help: entry.help)
        }
        metricsByKey = Dictionary(metrics.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The wire shape of one `rules` entry, before the nil-id ones are
    /// filtered out. Kept private and separate from `Rule` so `Rule.id`
    /// itself can stay non-optional — every other type in this app that
    /// models a list item CLI JSON produces keys its `Identifiable`
    /// conformance on a real value for the same reason.
    private struct RawRule: Decodable {
        var id: String?
        var title: String?
        var category: String?
        var severity: String?
        var scope: String?
        var blurb: String?
        var doc: String?

        enum CodingKeys: String, CodingKey { case id, title, category, severity, scope, blurb, doc }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(.id)
            title = c.lenient(.title)
            category = c.lenient(.category)
            severity = c.lenient(.severity)
            scope = c.lenient(.scope)
            blurb = c.lenient(.blurb)
            doc = c.lenient(.doc)
        }
    }

    /// The wire shape of one `metrics` entry — same reasoning as `RawRule`.
    private struct RawMetric: Decodable {
        var key: String?
        var label: String?
        var help: String?

        enum CodingKeys: String, CodingKey { case key, label, help }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.lenient(.key)
            label = c.lenient(.label)
            help = c.lenient(.help)
        }
    }
}
