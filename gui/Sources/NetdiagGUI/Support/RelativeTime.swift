import Foundation
import SwiftUI

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

/// A `Text` that keeps itself current, for a `Date` embedded in a leaf view
/// with nothing else to force a redraw.
///
/// `RelativeTime.string(from:)` computes a plain `String` at whatever
/// instant the caller's `body` happens to run. That is fine for a value
/// read directly inside a view that is already being asked to redraw for
/// other reasons — the dropdown's "Last check" line, rebuilt on every
/// monitor sample alongside the numbers it sits next to. It is wrong for a
/// standalone leaf view whose only input is the date itself, e.g.
/// `EventRow`: once its `NetworkEvent` stops changing, SwiftUI has no
/// tracked dependency telling it to call that view's `body` again, so the
/// string it printed the moment the row first appeared — often "0s", since
/// that is usually the instant the event was recorded — is what stays on
/// screen no matter how much real time passes. Confirmed live: the
/// dropdown's timeline froze at "11m ago" for a fixed event across eight
/// minutes of real time while `RelativeTime.string` was never called again
/// for that date, in the same window where an inline computation of the
/// same underlying timestamp (`quietLine`'s "Nothing has changed in Xm")
/// correctly advanced from 11m to 19m.
///
/// `TimelineView` gives the leaf its own reason to redraw, independent of
/// whatever its input is doing.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(RelativeTime.string(from: date))
        }
    }
}
