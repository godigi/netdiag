import Foundation

/// Turns a `ScanProgress` phase list into a single completion fraction,
/// weighted by *durations measured on this machine* rather than by phase
/// count.
///
/// See `docs/design/watching-it-happen.md`'s "A plan, not a percentage"
/// section for why a bar was rejected in the first place, and for the
/// change of stance that makes this file possible: the CLI now emits a
/// `plan` naming every phase a mode will attempt and a `ms` on every
/// `done`, so there is finally a quantity — elapsed time, per phase, per
/// mode — for a percentage to be a percentage *of*. A count-based bar
/// ("12 of 28") is not that percentage: this app's own runs show the
/// speed test alone taking 65–115 s inside a run whose other ~27 phases
/// together take single-digit seconds, so a bar driven by phase count
/// would race to ~90% and then sit still for a minute — arguably more
/// dishonest than the plan-based line it would replace, because a
/// percentage carries an expectation a count never did.
///
/// A pure value type on purpose, with no dependency on `NetdiagCoordinator`
/// or any other live service. It reuses `ScanProgress.Phase` /
/// `.PhaseState` rather than re-declaring them — unlike `StageResolver`,
/// which deliberately decouples from `AlertEngine.ActiveAlert` (a
/// *service*-layer type reachable only through a live coordinator), those
/// two are plain, dependency-free value types one layer up in `Models/`,
/// so reusing them costs nothing and avoids a second copy of the state
/// machine drifting from the first. That purity is what lets
/// `VerifyMode.swift` construct inputs by hand and assert on the result —
/// the only kind of Swift logic this CLT-only toolchain can actually run a
/// test against; see `VerifyMode.swift`'s header.
struct PhaseWeights: Equatable, Sendable {

    /// Phases whose measured `ms` covers time other phases are *also*
    /// reporting, and which therefore contribute no weight of their own.
    ///
    /// `parallel_batch` is the only one today. `bin/netdiag` launches ten
    /// checks concurrently — each emitting its own `start`/`done` on fd 3
    /// the moment it lands — and then wraps `collect_parallel` in a
    /// `run_timed parallel_batch`, so the batch's duration is the wall
    /// clock those ten shared. A real capture of a `--quick` run: dns 380,
    /// tcp_reach 120, path 110, hosts 22, ipv6 18 — and `parallel_batch`
    /// 395, spanning all of them. Counting both puts the same seconds in
    /// the denominator twice, which inflates the ETA and makes the bar
    /// advance faster than wall clock when the batch resolves.
    ///
    /// Dropping the wrapper rather than its children is the right way
    /// round: the children resolve one at a time and are what actually
    /// moves the bar during the batch, while the wrapper resolves once,
    /// last, and would move it in a single step. The row still appears in
    /// the phase grid — this is about weight, not visibility.
    static let overlappingPhases: Set<String> = ["parallel_batch"]

    /// How many of the most recent measured durations are kept per
    /// (mode, phase), and the estimate reported is their **median**.
    ///
    /// Median over mean or an EWMA, specifically: a single stalled phase —
    /// a two-second DNS hiccup that pads one phase from 200 ms to 20 s —
    /// must not move next run's bar. With an odd-sized window the outlier
    /// can only become the reported value if it lands in the *middle* once
    /// sorted, which one bad sample among several good ones never does. An
    /// EWMA does not have that property: every sample nudges it, so one
    /// spike is still partially baked in ten runs later, just by a
    /// shrinking amount each time. A window of 5 means one bad run needs
    /// four more of its own kind before it can affect the estimate at all,
    /// and it ages out completely after 5 good runs — "not for the next
    /// ten runs" with room to spare.
    static let historyWindow = 5

    /// mode -> phase name -> the last `historyWindow` measured durations
    /// (ms), oldest first. Raw samples rather than a running median so
    /// folding in a new run is an append-and-trim, and the median is
    /// computed on demand from whatever is currently in the window.
    private var samples: [String: [String: [Int]]]

    init(samples: [String: [String: [Int]]] = [:]) {
        self.samples = samples
    }

    // MARK: - Persistence

    /// Loads the store `Defaults.phaseDurationSamples` currently holds.
    static func loaded() -> PhaseWeights { PhaseWeights(samples: Defaults.phaseDurationSamples) }

    /// Writes this instance back to `Defaults.phaseDurationSamples`. The
    /// caller decides when — `ScanProgress.finish` is the only call site,
    /// so a run's own phases can never influence the bar it is still
    /// drawing.
    func save() { Defaults.phaseDurationSamples = samples }

    // MARK: - Learning

    /// Folds one finished run's measured durations in, returning the
    /// updated store. Only a phase that reached `.done` with a non-nil
    /// `ms` teaches anything: `.skipped` has no duration to learn (the CLI
    /// chose not to run it), and `.didNotRun` is the run being cut short —
    /// cancelled, crashed, or killed — which is a fact about that run, not
    /// about how long the phase takes.
    func learning(mode: String, phases: [ScanProgress.Phase]) -> PhaseWeights {
        guard !mode.isEmpty else { return self }
        var next = samples
        var perPhase = next[mode] ?? [:]
        for phase in phases {
            guard phase.state == .done, let ms = phase.ms, ms >= 0 else { continue }
            var series = perPhase[phase.name] ?? []
            series.append(ms)
            if series.count > Self.historyWindow {
                series.removeFirst(series.count - Self.historyWindow)
            }
            perPhase[phase.name] = series
        }
        next[mode] = perPhase
        return PhaseWeights(samples: next)
    }

    // MARK: - Reading

    /// Whether `mode` has learned a duration for at least one phase. The
    /// view uses this, not "is `remainingSeconds` non-nil", to decide
    /// whether an ETA is justified at all — see `Progress.isLearned`.
    func hasLearned(mode: String) -> Bool { !estimates(mode: mode).isEmpty }

    /// One phase's learned duration, in ms — the median of its recent
    /// samples for `mode`, or `nil` if `mode` has never seen this phase
    /// reach `.done`.
    private func estimates(mode: String) -> [String: Int] {
        let series = samples[mode] ?? [:]
        var result: [String: Int] = [:]
        for (phase, durations) in series
        where !durations.isEmpty && !Self.overlappingPhases.contains(phase) {
            result[phase] = median(durations)
        }
        // Filtered here rather than in `learning` so a store written
        // before `overlappingPhases` existed stops counting too, without
        // a migration.
        return result
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// A completion snapshot for one moment of a run in progress.
    struct Progress: Equatable, Sendable {
        /// The fraction of the run's *learned time* judged complete,
        /// clamped to `0...1`. Driven entirely by phase weights and phase
        /// state, so it can only increase within one run — see `progress`
        /// below for why.
        let fraction: Double
        /// Seconds of learned time left, or `nil` when `isLearned` is
        /// false. Already clamped to `>= 0`; a view must still decide what
        /// "basically zero" looks like rather than print a bare "0s",
        /// which reads as a countdown that finished when the run has not.
        let remainingSeconds: Double?
        /// True when at least one phase weight behind `fraction` came from
        /// learned history rather than the equal-weight fallback. The view
        /// gates the ETA on this, not on `remainingSeconds == nil`,
        /// because a run whose every remaining phase happens to be
        /// already-done would otherwise show `remainingSeconds` of exactly
        /// `0` and still claim a (correct, but coincidental) estimate.
        let isLearned: Bool
    }

    /// The bar's state for the current instant, from the phase list as
    /// `ScanProgress` has it plus the two phases that report their own
    /// sub-progress.
    ///
    /// **Weighting.** Each phase not `.skipped` / `.didNotRun` contributes
    /// its learned median (or, when `mode` has no history yet, an equal
    /// share) to both the numerator and the denominator; `.skipped` /
    /// `.didNotRun` phases contribute to neither. That is the
    /// re-normalisation the redesign asked for: a `--quick` run that skips
    /// the speed test does not leave ~40% of the bar's weight stranded
    /// forever, because that weight was never added to the denominator in
    /// the first place.
    ///
    /// **Monotonicity.** A `.pending` phase contributes 0 to the numerator;
    /// `.running` contributes its weight times the phase's own
    /// sub-progress (0 for every phase but the speed test and bufferbloat,
    /// which report one via `ScanProgress.speed.progress` /
    /// `.bufferbloat.progress`); `.done` contributes its full weight. None
    /// of those can go down as a run proceeds — a phase does not go from
    /// `.done` back to `.running`, and Ookla's own progress fraction does
    /// not run backwards — and a phase dropping to `.skipped` only ever
    /// removes weight from the denominator, which raises the fraction or
    /// leaves it unchanged, never lowers it. So `fraction` is non-decreasing
    /// across one run's events, by construction rather than by a clamp.
    func progress(mode: String, phases: [ScanProgress.Phase],
                  speedProgress: Double?, bufferbloatProgress: Double?) -> Progress {
        guard !phases.isEmpty else { return Progress(fraction: 0, remainingSeconds: nil, isLearned: false) }

        let learned = estimates(mode: mode)
        let isLearned = !learned.isEmpty
        // The fallback for a phase this mode has never measured: the mean
        // of what *has* been measured, when there is any, so one unlearned
        // phase amid many learned ones does not swing the bar wildly in
        // either direction. With nothing learned at all, every phase counts
        // the same — the honest first-run behaviour the old "N of M" line
        // already had, now expressed as equal weights instead of equal
        // rows.
        let fallback = isLearned
            ? Int((Double(learned.values.reduce(0, +)) / Double(learned.count)).rounded())
            : 1

        var totalWeight = 0.0
        var doneWeight = 0.0
        var remainingMs = 0.0

        for phase in phases {
            guard phase.state != .skipped, phase.state != .didNotRun,
                  !Self.overlappingPhases.contains(phase.name) else { continue }
            let weight = Double(learned[phase.name] ?? fallback)
            totalWeight += weight
            switch phase.state {
            case .done:
                doneWeight += weight
            case .running:
                let sub = subProgress(phase: phase.name, speed: speedProgress, bufferbloat: bufferbloatProgress)
                doneWeight += weight * sub
                remainingMs += weight * (1 - sub)
            case .pending:
                remainingMs += weight
            case .skipped, .didNotRun:
                break // excluded above; unreachable
            }
        }

        let fraction = totalWeight > 0 ? min(max(doneWeight / totalWeight, 0), 1) : 0
        let remaining = isLearned ? max(remainingMs, 0) / 1000 : nil
        return Progress(fraction: fraction, remainingSeconds: remaining, isLearned: isLearned)
    }

    /// The two phases whose fraction inside themselves is already known —
    /// everything else is 0 until it resolves to `.done`. Named by the
    /// CLI's own phase identifiers (`lib/common.sh`'s `progress_plan_phases`),
    /// not guessed: `"speedtest"` and `"bufferbloat"`.
    private func subProgress(phase: String, speed: Double?, bufferbloat: Double?) -> Double {
        switch phase {
        case "speedtest":   return min(max(speed ?? 0, 0), 1)
        case "bufferbloat": return min(max(bufferbloat ?? 0, 0), 1)
        default:             return 0
        }
    }
}
