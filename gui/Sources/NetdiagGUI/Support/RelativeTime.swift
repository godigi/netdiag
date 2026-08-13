import Foundation

/// One `RelativeDateTimeFormatter` for every "2h ago" the app renders —
/// the dropdown's alert rows and "Last check" line, Home's recent checks.
/// Constructing one per row is the same needless cost `HistoryDocument.iso`
/// documents for `ISO8601DateFormatter`, at smaller scale — and two views
/// each hiding a private copy is how the two drift apart. Sharing one is
/// sound for the same reason `HistoryDocument.iso` gives: every caller is
/// `@MainActor`.
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}
