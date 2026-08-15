import Foundation

/// Structured metadata for a GitHub release.
struct GitHubRelease: Decodable, Sendable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlUrl: URL?
    var publishedAt: String?
    var assets: [GitHubAsset] = []

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    var cleanVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }
}

/// A release asset attached to a GitHub release (e.g. `Netdiag.dmg`, `Netdiag.app.zip`).
struct GitHubAsset: Decodable, Sendable, Identifiable {
    var id: Int
    var name: String
    var browserDownloadUrl: URL
    var size: Int?
    var contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
        case contentType = "content_type"
    }

    var isInstallableArchive: Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") || lower.hasSuffix(".dmg") || lower.hasSuffix(".tar.gz")
    }
}

/// Robust semantic version parser and comparator.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let raw: String

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init(_ string: String) {
        self.raw = string
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let components = cleaned.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        self.major = components.count > 0 ? components[0] : 0
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}
