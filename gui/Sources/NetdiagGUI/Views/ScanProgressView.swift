import SwiftUI

/// The phase list that replaced the spinner, now topped with a determinate
/// bar.
///
/// Every row states one of three facts about a *check*: it ran, it was
/// skipped, or it did not complete. None of them is a fact about the
/// network. A phase is never coloured by how good its number was — that
/// judgement is `lib/diagnosis.sh`'s, it arrives in `diagnosis[].summary`,
/// and a progress list that pre-empted it with a red row would be the app
/// diagnosing on its own.
///
/// The bar above the grid is `Support/PhaseWeights.swift`'s fraction, not a
/// second opinion computed here — this view's job is to draw the number,
/// never to invent one. The "N of M · phase · mode" line stays exactly as
/// it was: the bar complements that count, it does not replace it, because
/// the count is still the honest answer to "how many checks are left" even
/// when the bar's answer to "how much longer" is a guess this build has not
/// yet earned (see `overallBar`).
struct ScanProgressView: View {
    var progress: ScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.hasPlan {
                overallBar
                summary
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
                          alignment: .leading, spacing: 4) {
                    ForEach(progress.phases) { row($0) }
                }
                if let speed = progress.speed { speedRow(speed) }
            } else {
                // No plan yet. Either the run has not announced one, or the
                // installed netdiag predates --progress and never will —
                // indistinguishable from here, and an indeterminate spinner
                // is the honest answer to both.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The determinate bar. Its fraction comes from `PhaseWeights`, weighted
    /// by durations measured on *this* machine on *this* mode; the ETA
    /// underneath is shown only once that history exists at all —
    /// `snapshot.isLearned` — because an ETA built from equal-weight guesses
    /// on a fresh install would claim precision the app does not have.
    private var overallBar: some View {
        let snapshot = progress.weights.progress(
            mode: progress.mode ?? "",
            phases: progress.phases,
            speedProgress: progress.speed?.progress,
            bufferbloatProgress: progress.bufferbloat?.progress)
        return VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: snapshot.fraction)
            if let eta = etaText(snapshot) {
                Text(eta).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// `nil` before any history exists for this mode — the "unlearned"
    /// state the bar shows without a time. Once learned, a countdown that
    /// has run down to (or below, from rounding) a couple of seconds reads
    /// as "finishing up" rather than as "0s left", which would look like a
    /// stalled or backwards-running clock on a phase that has not actually
    /// finished.
    private func etaText(_ snapshot: PhaseWeights.Progress) -> String? {
        guard snapshot.isLearned else { return nil }
        guard let remaining = snapshot.remainingSeconds, remaining > 2 else {
            return "Finishing up…"
        }
        return "About \(Self.formatted(seconds: remaining)) left"
    }

    private var summary: some View {
        HStack(spacing: 6) {
            // A count of a declared list, kept beside the bar rather than
            // replaced by it. The two answer different questions — how
            // many checks are left, and how much longer — and only the
            // first is exact. On a fresh install it is also the only one
            // the app can answer at all, since the bar has no learned
            // durations to weight itself by yet.
            Text("\(progress.resolvedCount) of \(progress.plannedCount)")
                .monospacedDigit()
            if let running = progress.runningPhase {
                Text("· \(running.label.lowercased())")
            }
            if let mode = progress.mode {
                Text("· \(mode)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(_ phase: ScanProgress.Phase) -> some View {
        HStack(spacing: 6) {
            icon(phase).frame(width: 14)
            Text(phase.label)
                .foregroundStyle(phase.state == .pending ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing = trailing(phase) {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .help(phase.why ?? "")
    }

    @ViewBuilder
    private func icon(_ phase: ScanProgress.Phase) -> some View {
        switch phase.state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            // Green for "the check completed", amber for "it didn't" —
            // both statements about the tool. rc is the check function's
            // exit status, not a verdict on the link.
            Image(systemName: (phase.rc ?? 0) == 0 ? "checkmark.circle.fill"
                                                   : "exclamationmark.circle")
                .foregroundStyle((phase.rc ?? 0) == 0 ? Color.green : Color.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .didNotRun:
            Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        }
    }

    /// The right-hand column. "not measured" is never rendered as a number,
    /// and a phase with no duration shows no duration.
    private func trailing(_ phase: ScanProgress.Phase) -> String? {
        switch phase.state {
        case .pending, .running:
            return nil
        case .done:
            let rc = phase.rc ?? 0
            let duration = phase.ms.map(Self.formatted(ms:))
            if rc != 0 { return duration.map { "exit \(rc) · \($0)" } ?? "exit \(rc)" }
            return duration
        case .skipped:
            return phase.why ?? "skipped"
        case .didNotRun:
            return "didn't run"
        }
    }

    /// Ookla streams its stages; `speedtest-cli` does not. A missing
    /// fraction shows an indeterminate bar rather than invented motion.
    @ViewBuilder
    private func speedRow(_ speed: ScanProgress.Speed) -> some View {
        HStack(spacing: 8) {
            if let fraction = speed.progress {
                ProgressView(value: min(max(fraction, 0), 1))
                    .frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(speed.stage.isEmpty ? "Speed test" : PhaseLabel.humanised(speed.stage))
            if let mbps = speed.mbps {
                Text(String(format: "%.1f Mbps", mbps)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func formatted(ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }

    /// A rounded, human-scale "about how long" — "45s", "1m 20s", "2m" —
    /// never sub-second precision an estimate this coarse cannot back up.
    static func formatted(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
    }
}

/// The one-line form, for the dropdown. Same model, no room for a grid or a
/// bar — so the one-line equivalent of `overallBar` is text, appended to the
/// count rather than replacing it, and only once it is learned. The speed
/// line is left alone: it already shows live throughput and a stage name,
/// and a third clause there would crowd the one line that is busiest at
/// exactly the point in a run where crowding it is worst.
struct ScanProgressLine: View {
    var progress: ScanProgress

    var body: some View {
        if let speed = progress.speed {
            Text(speedLabel(speed))
        } else if progress.hasPlan {
            Text(countLabel).monospacedDigit()
        } else {
            Text("Working…")
        }
    }

    private var countLabel: String {
        var text = "\(progress.resolvedCount) of \(progress.plannedCount)"
        if let running = progress.runningPhase {
            text += " · \(running.label.lowercased())"
        }
        if let eta = etaSuffix {
            text += " · \(eta)"
        }
        return text
    }

    private var etaSuffix: String? {
        let snapshot = progress.weights.progress(
            mode: progress.mode ?? "",
            phases: progress.phases,
            speedProgress: progress.speed?.progress,
            bufferbloatProgress: progress.bufferbloat?.progress)
        guard snapshot.isLearned, let remaining = snapshot.remainingSeconds, remaining > 2 else {
            return nil
        }
        return "\(ScanProgressView.formatted(seconds: remaining)) left"
    }

    private func speedLabel(_ speed: ScanProgress.Speed) -> String {
        let stage = speed.stage.isEmpty ? "Speed test" : PhaseLabel.humanised(speed.stage)
        guard let mbps = speed.mbps else { return stage }
        return String(format: "%@ · %.1f Mbps", stage, mbps)
    }
}
