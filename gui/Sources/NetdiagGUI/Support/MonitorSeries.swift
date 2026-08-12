import Foundation

/// Turns a run of monitor samples into line segments, leaving the gaps as
/// gaps.
///
/// The monitor is not a continuous recorder and never claimed to be. It
/// pauses for system sleep, for display sleep, and for the whole duration of
/// every scan; it restarts when a cadence setting changes; and it dies and
/// backs off if the binary goes missing. A line drawn straight across any of
/// those asserts measurements that were never taken — the same lie the
/// History tab's "no data" panel exists to refuse, and it is worse here
/// because a smooth line through a two-minute outage is *reassuring*.
///
/// Nothing in this file judges a value. It decides only whether two points
/// were close enough in time to be joined.
enum MonitorSeries {

    struct Point: Identifiable, Equatable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// A stretch of wall-clock with no samples in it.
    struct Gap: Identifiable, Equatable {
        let start: Date
        let end: Date
        var id: Date { start }
    }

    struct Result {
        /// One entry per unbroken stretch. Charts draw each as its own
        /// series so no line spans two of them.
        var segments: [[Point]] = []
        var gaps: [Gap] = []

        var points: [Point] { segments.flatMap { $0 } }
        var isEmpty: Bool { points.isEmpty }
        var latest: Point? { segments.last?.last }
    }

    /// Build one series.
    ///
    /// - Parameters:
    ///   - tier: which cadence tier measures this value — `"fast"`,
    ///     `"medium"` or `"slow"`. Samples where that tier was not due carry
    ///     the previous cycle's number verbatim, and plotting them would
    ///     turn one measurement into six.
    ///   - value: `nil` means not measured, never zero.
    static func build(_ samples: [MonitorSample], tier: String,
                      value: (MonitorSample) -> Double?) -> Result {
        var result = Result()
        var current: [Point] = []
        var previous: MonitorSample?

        func closeSegment() {
            if !current.isEmpty { result.segments.append(current) }
            current = []
        }

        for sample in samples {
            let now = sample.timestamp

            if let previous {
                // The tolerance comes from the samples themselves, so a
                // monitor running at 2 s during a latency test and one
                // running at 10 s are held to their own standards.
                //
                // Two cadences rather than one-and-a-bit: `cadence_s` is
                // the sleep *between* probes, so a healthy stream's real
                // interval is cadence plus probe time — the gateway ping
                // alone is ~2 s of a 10 s cycle. A tighter tolerance would
                // shred a perfectly continuous hour into phantom gaps.
                let cadence = Double(previous.status.cadenceS ?? 0)
                if cadence > 0, now.timeIntervalSince(previous.timestamp) > cadence * 2 {
                    result.gaps.append(Gap(start: previous.timestamp, end: now))
                    closeSegment()
                }
            }
            previous = sample

            // A paused sample is the monitor saying so out loud: probing is
            // suspended and every number in it is carried over from before
            // the pause. docs/JSON-SCHEMA.md — do not plot it.
            if sample.status.paused {
                closeSegment()
                continue
            }

            // This tier was not due this cycle. Not a gap: nothing was
            // missed, this value simply is not measured every cycle, and
            // the point marks make its real density visible.
            guard sample.refreshed.contains(tier) else { continue }

            guard let measured = value(sample) else {
                // The tier ran and came back with nothing — a down link, a
                // ping that got no reply. Joining across it would draw a
                // round-trip time through an outage.
                closeSegment()
                continue
            }

            current.append(Point(date: now, value: measured))
        }

        closeSegment()
        return result
    }
}
