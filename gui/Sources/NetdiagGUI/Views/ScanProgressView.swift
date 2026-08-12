import SwiftUI

/// The phase list that replaced the spinner.
///
/// Every row states one of three facts about a *check*: it ran, it was
/// skipped, or it did not complete. None of them is a fact about the
/// network. A phase is never coloured by how good its number was — that
/// judgement is `lib/diagnosis.sh`'s, it arrives in `diagnosis[].summary`,
/// and a progress list that pre-empted it with a red row would be the app
/// diagnosing on its own.
struct ScanProgressView: View {
    var progress: ScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.hasPlan {
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

    private var summary: some View {
        HStack(spacing: 6) {
            // A count of a declared list, not a percentage: --json emits
            // nothing until the end, so there is no total duration to be a
            // fraction of.
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
}

/// The one-line form, for the dropdown. Same model, no room for a grid.
struct ScanProgressLine: View {
    var progress: ScanProgress

    var body: some View {
        if let speed = progress.speed {
            Text(speedLabel(speed))
        } else if progress.hasPlan {
            Text("\(progress.resolvedCount) of \(progress.plannedCount)"
                 + (progress.runningPhase.map { " · \($0.label.lowercased())" } ?? ""))
                .monospacedDigit()
        } else {
            Text("Working…")
        }
    }

    private func speedLabel(_ speed: ScanProgress.Speed) -> String {
        let stage = speed.stage.isEmpty ? "Speed test" : PhaseLabel.humanised(speed.stage)
        guard let mbps = speed.mbps else { return stage }
        return String(format: "%@ · %.1f Mbps", stage, mbps)
    }
}
