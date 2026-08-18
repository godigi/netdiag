// This CLT-only toolchain (no Xcode.app — see Package.swift's header) does
// not ship XCTest.framework for macOS; only Swift Testing
// (CommandLineTools/Library/Developer/Frameworks/Testing.framework) is
// present. `import XCTest` fails to resolve here, so these tests use Swift
// Testing (`@Test` / `#expect`) instead — same four cases, same pure
// NetworkEvent helpers, no XCTest dependency.
import Foundation
import Testing
@testable import NetdiagGUI

struct NetworkEventTests {
    private func event(minutesAgo: Double, kind: String = "public-ip-changed",
                       summary: String = "s", now: Date) -> NetworkEvent {
        NetworkEvent(date: now.addingTimeInterval(-minutesAgo * 60),
                     kind: kind, summary: summary)
    }

    @Test func trimKeepsNewestFirstAndCaps() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = (0..<10).map { event(minutesAgo: Double($0), now: now) }
        let trimmed = NetworkEvent.trimmed(events.shuffled(), cap: 3)
        #expect(trimmed.count == 3)
        #expect(trimmed.map(\.date) == events.prefix(3).map(\.date))
    }

    @Test func timeSinceLastUsesNewestEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = [event(minutesAgo: 30, now: now),
                      event(minutesAgo: 5, now: now)]
        #expect(NetworkEvent.timeSinceLast(events, now: now) == 300)
        #expect(NetworkEvent.timeSinceLast([], now: now) == nil)
    }

    @Test func withinFiltersByCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = [event(minutesAgo: 30, now: now),
                      event(minutesAgo: 25 * 60, now: now)]
        #expect(NetworkEvent.within(events, hours: 24, now: now).count == 1)
    }

    @Test func isRepeatCoalescesOnlyExactRecentDuplicates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let newest = event(minutesAgo: 5, kind: "rule-fired",
                           summary: "Issue G2 detected", now: now)
        #expect(NetworkEvent.isRepeat(
            kind: "rule-fired", summary: "Issue G2 detected",
            date: now, in: [newest]))
        #expect(!NetworkEvent.isRepeat(
            kind: "rule-fired", summary: "Issue G3 detected",
            date: now, in: [newest]))
        #expect(!NetworkEvent.isRepeat(
            kind: "alert", summary: "Issue G2 detected",
            date: now, in: [newest]))
        #expect(!NetworkEvent.isRepeat(
            kind: "rule-fired", summary: "Issue G2 detected",
            date: now.addingTimeInterval(700), in: [newest]))
        #expect(!NetworkEvent.isRepeat(
            kind: "rule-fired", summary: "Issue G2 detected",
            date: now, in: []))
    }

    /// A rule that clears and immediately re-fires (a flap) must still be
    /// coalesced with the fired event two entries back — the scan has to
    /// look past the newest entry, not stop at it. `events` is
    /// newest-first, matching EventStore's invariant.
    @Test func isRepeatScansPastTheNewestEntryWithinTheWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let firedSummary = "Issue G2 detected"
        let cleared = event(minutesAgo: 1, kind: "rule-cleared",
                            summary: "Issue G2 cleared", now: now)
        let fired = event(minutesAgo: 2, kind: "rule-fired",
                          summary: firedSummary, now: now)
        let events = [cleared, fired]

        #expect(NetworkEvent.isRepeat(
            kind: "rule-fired", summary: firedSummary,
            date: now, in: events))

        let longAgoCleared = event(minutesAgo: 11, kind: "rule-cleared",
                                   summary: "Issue G2 cleared", now: now)
        let longAgoFired = event(minutesAgo: 12, kind: "rule-fired",
                                 summary: firedSummary, now: now)
        #expect(!NetworkEvent.isRepeat(
            kind: "rule-fired", summary: firedSummary,
            date: now, in: [longAgoCleared, longAgoFired]))
    }
}
