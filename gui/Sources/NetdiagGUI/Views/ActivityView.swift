import SwiftUI

/// Every CLI-reported change and fired alert, newest first, grouped by
/// calendar day — the full list the dropdown's three-row timeline teases.
/// Reads `coordinator.eventLog` (the durable `EventStore`, not
/// `coordinator.events`, the unrelated CoreWLAN/NWPath watcher) and renders
/// with `EventRow`, the same building block the dropdown uses, so a change
/// reads identically in both places.
struct ActivityView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator

    private var events: [NetworkEvent] { coordinator.eventLog.events }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Divider()
            List {
                if days.isEmpty {
                    emptyState
                } else {
                    ForEach(days) { day in
                        Section(day.label) {
                            ForEach(day.events) { EventRow(event: $0) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Activity").font(.headline)
            Text(events.isEmpty ? "No events yet" : "\(events.count) event(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Label("No events recorded yet — changes and alerts will appear here as monitoring notices them.",
              systemImage: "clock.arrow.circlepath")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    // MARK: - Day grouping

    private struct Day: Identifiable {
        let id: String
        let label: String
        let events: [NetworkEvent]
    }

    /// One section per calendar day, newest first. `events` is already in
    /// that order (`EventStore`'s invariant), so the days come out of it in
    /// order too.
    private var days: [Day] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [NetworkEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(event)
        }
        return order.map {
            Day(id: "\($0.timeIntervalSince1970)", label: dayLabel($0), events: buckets[$0] ?? [])
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        // "Today" and "Yesterday" where they apply — same relative-date
        // formatting RunListView's day grouping uses, for the same reason:
        // the recent events are the interesting ones, and a full date
        // makes the reader work out which of them that is.
        f.doesRelativeDateFormatting = true
        return f.string(from: day)
    }
}
