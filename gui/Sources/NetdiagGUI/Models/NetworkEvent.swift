import Foundation

/// One thing that changed, as told by the CLI — a monitor `changes`
/// entry or a fired alert. The GUI stores and renders these; it never
/// authors the summary text.
struct NetworkEvent: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    /// Stream change kind ("vpn-disconnected", "rule-fired", …) or
    /// "alert" for alert-engine events. Drives icon/tint mapping only.
    let kind: String
    let summary: String
    let ruleID: String?

    init(id: UUID = UUID(), date: Date, kind: String,
         summary: String, ruleID: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.ruleID = ruleID
    }
}

extension NetworkEvent {
    /// Newest-first, capped. Pure so the test target can hit it.
    static func trimmed(_ events: [NetworkEvent], cap: Int) -> [NetworkEvent] {
        Array(events.sorted { $0.date > $1.date }.prefix(cap))
    }

    /// Interval since the newest event, or nil when there is none.
    static func timeSinceLast(_ events: [NetworkEvent],
                              now: Date) -> TimeInterval? {
        guard let newest = events.map(\.date).max() else { return nil }
        return now.timeIntervalSince(newest)
    }

    static func within(_ events: [NetworkEvent], hours: Double,
                       now: Date) -> [NetworkEvent] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return events.filter { $0.date >= cutoff }
    }

    /// A flapping condition or a resume-from-sleep burst repeats the
    /// same CLI phrase; storing every copy would evict real history.
    static func isRepeat(kind: String, summary: String, date: Date,
                         of newest: NetworkEvent?,
                         window: TimeInterval = 600) -> Bool {
        guard let newest else { return false }
        return newest.kind == kind && newest.summary == summary
            && abs(date.timeIntervalSince(newest.date)) < window
    }
}
