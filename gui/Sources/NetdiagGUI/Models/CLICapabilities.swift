import Foundation

/// Lenient-decoded model of `netdiag --capabilities` — see "netdiag
/// --capabilities schema" in docs/JSON-SCHEMA.md for the wire shape this
/// mirrors, and helpers/capabilities.py for what actually writes it.
///
/// Decoded through `KeyedDecodingContainer.lenient` exactly like a stored
/// record is (see LenientDecoding.swift's header) even though every value
/// here comes from a live handshake rather than a JSONL file on disk: a
/// GUI can be older than the CLI it finds just as easily as the reverse,
/// and a future schema bump that adds, drops or retypes a field must
/// degrade that one field to "unknown" rather than fail the whole probe.
struct CLICapabilities: Decodable, Sendable {
    var schema: Int?
    var version: String?
    /// Schema number of six other outputs (`run`, `monitor`, `history`,
    /// `show`, `rules_catalog`, `progress`), keyed exactly as
    /// docs/JSON-SCHEMA.md names them. Nothing in this app reads an entry
    /// here to decide behavior yet — `Feature` membership below is what
    /// gating uses — so this is carried through only to be shown, in the
    /// About section's expert-ish caption.
    var schemas: [String: Int]?
    /// An open set, not a closed enum — see docs/JSON-SCHEMA.md: "expect
    /// it to grow as new CLI surface ships. A GUI checks membership, not
    /// the array's length or order."
    var features: Set<String> = []
    var deps: Deps = .init()

    enum CodingKeys: String, CodingKey { case schema, version, schemas, features, deps }

    /// Whether `feature` (one of the strings docs/JSON-SCHEMA.md's
    /// `features` array can carry) is in the set this CLI reported.
    func supports(_ feature: String) -> Bool { features.contains(feature) }

    struct Deps: Decodable, Sendable {
        var bash: String?
        var python3: String?
        var jq: Bool?
        /// `"ookla"`, `"cli"` (the speedtest-cli Python package), or nil
        /// if neither is installed — never a plain `Bool`, so "not
        /// installed" and "installed, but which one" can't be confused.
        /// See docs/JSON-SCHEMA.md's `deps.speedtest`.
        var speedtest: String?
        var mtr: Bool?
        var gping: Bool?

        enum CodingKeys: String, CodingKey { case bash, python3, jq, speedtest, mtr, gping }
    }
}

extension CLICapabilities {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema)
        version = c.lenient(.version)
        schemas = c.lenient(.schemas)
        features = c.lenient(.features, [])
        deps = c.lenient(.deps, .init())
    }
}

extension CLICapabilities.Deps {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bash = c.lenient(.bash)
        python3 = c.lenient(.python3)
        jq = c.lenient(.jq)
        speedtest = c.lenient(.speedtest)
        mtr = c.lenient(.mtr)
        gping = c.lenient(.gping)
    }
}

/// Where a probe of `--capabilities` landed. `CapabilityStore` is the only
/// thing that produces one of these; every gated call site — and the
/// About section — reads it rather than re-deriving "is this CLI old
/// enough" from a version string of its own.
enum CapabilityState: Sendable {
    /// The CLI answered `--capabilities` and this is what it said.
    case modern(CLICapabilities)
    /// The CLI exited 3 on `--capabilities` — an unknown flag to it,
    /// exactly how every CLI built before commit 85bc9b4 (this
    /// handshake's own introduction) answers a flag it has never heard
    /// of. Kept distinct from `.unavailable` on purpose: only *this* case
    /// justifies falling back to the older, narrower `--progress --help`
    /// probe, because only this case is "the CLI is there and coherent,
    /// just old" rather than "something about running it at all failed".
    case legacy(supportsProgress: Bool)
    /// The probe couldn't establish either of the above — no binary, a
    /// spawn failure, or `--capabilities` exiting 0 with something that
    /// didn't decode as JSON. Gated the same as `.legacy` (nothing beyond
    /// `--json`/`--help`-family flags is trusted) but carries no CLI
    /// version to report.
    case unavailable
}

/// The app's own version, and — via `CapabilityStore.requiredVersion` —
/// the CLI version this build requires.
///
/// `gui/Makefile`'s `bundle` target stamps `CFBundleShortVersionString`
/// from the bundled CLI's own `NETDIAG_VERSION` at build time (see that
/// target's comment), so the two numbers are the same fact read from two
/// places, not two facts that could quietly disagree. That equality is
/// what lets the version-skew message read this instead of carrying a
/// second, hand-updated literal: "the CLI version this app needs" *is*
/// "the CLI version this app shipped with".
enum AppVersion {
    /// The literal template value in the checked-in Info.plist (see its
    /// own header) — recognised here once, so every caller that wants to
    /// say "dev build" instead of a fabricated number doesn't re-check
    /// the string for itself.
    static let unstamped = "0.0.0-unstamped"

    /// Read once: `Bundle.main`'s Info.plist doesn't change at runtime.
    static let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? unstamped

    /// What a person reads in the About section — "dev build" rather than
    /// a fabricated version number for a `swift build` that never ran
    /// `make bundle`.
    static var display: String { raw == unstamped ? "dev build" : raw }

    /// `version` as it should appear inside a sentence: "v0.9.0" — or,
    /// for the unstamped template value a bare `swift build` carries,
    /// prose that doesn't parade a fabricated number ("this app needs
    /// v0.0.0-unstamped or newer" is not a sentence to ship).
    static func phrase(for version: String) -> String {
        version == unstamped ? "the version this app shipped with" : "v\(version)"
    }
}
