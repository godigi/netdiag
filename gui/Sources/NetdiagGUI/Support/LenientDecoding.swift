import Foundation

/// Decoding for JSON whose shape the CLI has already changed.
///
/// Swift's synthesized `Decodable` does **not** fall back to the default
/// written beside a property when a key is missing — it throws
/// `keyNotFound`. That is harmless for `netdiag --json`, where the app is
/// reading a run the CLI produced moments ago, and wrong for
/// `~/net-diag/baseline.jsonl`, which holds every record the CLI has ever
/// written. Measured against the store this was built on: of 1,986 stored
/// runs, 1,926 have no `network` and no `timings` object, 1,923 have no
/// `internet_latency`, 1,854 have no `traceroute`, and 1,863 have no
/// `mtr.hops`. A strict decode opens 3% of the user's own history and
/// reports the rest as corrupt.
///
/// So every field of a model that reads a *stored* record goes through one
/// of these. A key that is absent, null, or of an unexpected type means
/// "the netdiag that wrote this record did not record that" — which is
/// exactly what the property's default already says.
extension KeyedDecodingContainer {

    /// The decoded value, or the default when the key is missing, null, or
    /// holds something of the wrong type.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return value
    }

    /// The optional-property form. `nil` here carries the same meaning it
    /// carries everywhere else in this app: not measured, never zero.
    func lenient<T: Decodable>(_ key: Key) -> T? {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return nil }
        return value
    }
}
