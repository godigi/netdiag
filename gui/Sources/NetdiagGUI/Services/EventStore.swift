import Foundation
import OSLog

/// The dropdown's change timeline and the "nothing has changed in N"
/// headline both read from here. Events come from the monitor stream's
/// `changes` array and from fired alerts; the monitor itself writes
/// nothing to disk (its contract), so durable memory lives GUI-side.
@MainActor
@Observable
final class EventStore {
    static let cap = 500

    private(set) var events: [NetworkEvent] = []

    private let log = Logger(subsystem: "me.brianfreeman.netdiag",
                             category: "events")
    private let url: URL?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Bundle.main.bundleIdentifier
                                    ?? "me.brianfreeman.netdiag",
                                    isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("events.json")
        } else {
            url = nil
        }
        load()
    }

    func record(kind: String, summary: String, ruleID: String? = nil,
                date: Date = .now) {
        guard !summary.isEmpty else { return }
        guard !NetworkEvent.isRepeat(kind: kind, summary: summary,
                                     date: date, of: events.first) else {
            return
        }
        events = NetworkEvent.trimmed(
            events + [NetworkEvent(date: date, kind: kind,
                                   summary: summary, ruleID: ruleID)],
            cap: Self.cap)
        save()
    }

    func within(hours: Double, now: Date = .now) -> [NetworkEvent] {
        NetworkEvent.within(events, hours: hours, now: now)
    }

    var lastEventDate: Date? { events.first?.date }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([NetworkEvent].self,
                                                     from: data)
        else { return }
        events = NetworkEvent.trimmed(stored, cap: Self.cap)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(events)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
