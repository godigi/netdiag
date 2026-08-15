import Foundation

/// One run in flight, as the run itself describes it.
///
/// Fed by the fd-3 progress stream documented in
/// `docs/design/watching-it-happen.md`: a `plan` naming the phases this mode
/// will attempt, then a `start`/`done`/`skip` per phase, then one `run done`.
///
/// **A plan, not a percentage.** `--json` produces nothing until the very
/// end, so there is no quantity a percentage could be a percentage *of*.
/// "17 of 28" is a true statement about a declared list; a progress bar
/// would be an invented one.
///
/// Note what is *not* here, and must never be: no thresholds, no judgement
/// of the numbers a phase produced. This type knows whether a check ran,
/// was skipped, or failed to complete — three facts about the *tool*. What
/// the check found is `diagnosis[].summary`'s business, and the CLI writes
/// that prose.
@MainActor
@Observable
final class ScanProgress {

    /// Five states, and each one is a fact about the check rather than
    /// about the network. `didNotRun` exists because a plan is a *declared*
    /// list: a phase can be planned and never reported, and the alternative
    /// to naming that is a row that spins forever.
    enum PhaseState: Equatable {
        case pending, running, done, skipped, didNotRun
    }

    struct Phase: Identifiable, Equatable {
        let name: String
        var state: PhaseState = .pending
        /// The check function's exit status. Non-zero means the check did
        /// not complete — not that it found something wrong.
        var rc: Int32?
        var ms: Int?
        /// The CLI's own reason for a skip, truncated at the source to keep
        /// fd-3 writes under PIPE_BUF.
        var why: String?

        var id: String { name }

        var label: String { PhaseLabel.humanised(name) }

        var isResolved: Bool {
            state == .done || state == .skipped || state == .didNotRun
        }
    }

    /// Ookla streams its stages; `speedtest-cli` does not. `progress == nil`
    /// means the stage is known and its fraction is not — which renders as
    /// an indeterminate bar rather than as invented motion.
    struct Speed: Equatable {
        var stage: String
        var progress: Double?
        var mbps: Double?
    }

    struct Bufferbloat: Equatable {
        var stage: String
        var progress: Double?
        var gwMs: Double?
        var inetMs: Double?
    }

    private(set) var mode: String?
    private(set) var phases: [Phase] = []
    private(set) var speed: Speed?
    private(set) var bufferbloat: Bufferbloat?
    private(set) var exitCode: Int32?
    /// True once the CLI has announced a plan. False through a whole run
    /// means the installed netdiag predates `--progress` — the UI falls
    /// back to the spinner rather than showing an empty list.
    private(set) var hasPlan = false
    private(set) var isFinished = false

    var resolvedCount: Int { phases.filter(\.isResolved).count }
    var plannedCount: Int { phases.count }

    /// The phase currently running, for the dropdown's one-line summary.
    var runningPhase: Phase? { phases.first { $0.state == .running } }

    // MARK: - Lifecycle

    func reset() {
        mode = nil
        phases = []
        speed = nil
        bufferbloat = nil
        exitCode = nil
        hasPlan = false
        isFinished = false
    }

    /// Called when the child process is gone, whatever the reason.
    ///
    /// The `run done` event is the normal path; this is the one that keeps
    /// a cancelled, crashed or killed run from leaving a row spinning. Both
    /// end in the same place, so calling it twice is harmless.
    func processEnded(exit code: Int32?) {
        finish(exit: code ?? exitCode)
    }

    // MARK: - Ingest

    /// One line of the child's stderr.
    ///
    /// Lines that are not JSON are dropped without a word. That is the
    /// deliberate difference from `MonitorStream`, which logs an
    /// undecodable line: there, every line is supposed to be a sample and a
    /// bad one is a bug worth seeing. Here the same stream also carries the
    /// CLI's ordinary human warnings, so logging each of them would bury
    /// the signal in exactly the noise it is mixed with.
    func ingest(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let event = try? JSONDecoder().decode(ProgressEvent.self, from: data)
        else { return }
        apply(event)
    }

    private func apply(_ event: ProgressEvent) {
        switch event.t {
        case "plan":
            mode = event.mode
            phases = (event.phases ?? []).map { Phase(name: $0) }
            hasPlan = true
            isFinished = false
            exitCode = nil

        case "phase":
            guard let name = event.name else { return }
            let index = indexOrAppend(name)
            switch event.state {
            case "start":
                phases[index].state = .running
            case "done":
                phases[index].state = .done
                phases[index].rc = event.rc
                phases[index].ms = event.ms
            case "skip":
                phases[index].state = .skipped
                phases[index].why = event.why
            default:
                break
            }

        case "speed":
            speed = Speed(stage: event.stage ?? "", progress: event.progress,
                          mbps: event.mbps)

        case "bufferbloat":
            bufferbloat = Bufferbloat(stage: event.stage ?? "", progress: event.progress,
                                      gwMs: event.gwMs, inetMs: event.inetMs)

        case "run":
            if event.state == "done" { finish(exit: event.exit) }

        default:
            break
        }
    }

    /// A phase the plan did not name still gets a row.
    ///
    /// The CLI has a bats test asserting plan-vs-wrapper parity, so this
    /// should be unreachable — but if it ever drifts, showing the check
    /// that actually ran beats silently discarding it.
    private func indexOrAppend(_ name: String) -> Int {
        if let index = phases.firstIndex(where: { $0.name == name }) { return index }
        phases.append(Phase(name: name))
        return phases.count - 1
    }

    private func finish(exit code: Int32?) {
        guard !isFinished else { return }
        isFinished = true
        exitCode = code
        // Anything unresolved when the run ends never reported. `.running`
        // counts as unresolved for the same reason `.pending` does: the row
        // has no result and never will, and a spinner that outlives its
        // process is the single worst thing a progress view can do.
        for index in phases.indices where !phases[index].isResolved {
            phases[index].state = .didNotRun
        }
    }
}

/// `wifi_scan` → "Wifi scan"; Ookla's `testStart` → "Test start".
///
/// A mechanical transform, deliberately, not a lookup table. A table would
/// render every phase the CLI gains after this build as a raw identifier,
/// and the only way to keep it current would be to write descriptions of
/// checks in Swift — which is the thing `lib/` owns. Two conventions
/// because two sources: phase names are the CLI's own snake_case
/// identifiers, speed stages are Ookla's camelCase ones passed through.
enum PhaseLabel {
    static func humanised(_ raw: String) -> String {
        var spaced = ""
        for character in raw.replacingOccurrences(of: "_", with: " ") {
            if character.isUppercase, !spaced.isEmpty, spaced.last != " " {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        let lowered = spaced.lowercased()
        return lowered.prefix(1).uppercased() + lowered.dropFirst()
    }
}

/// One line of the fd-3 progress stream.
///
/// A single flat type for all five event shapes rather than an enum with
/// associated values: the wire format is a tagged union with sparse fields,
/// and decoding it as one lenient bag means a future event type, or a
/// future field on an existing one, costs nothing here.
struct ProgressEvent: Decodable, Sendable {
    var t: String = ""
    var name: String?
    var state: String?
    var phases: [String]?
    var mode: String?
    var rc: Int32?
    var ms: Int?
    var why: String?
    var exit: Int32?
    var stage: String?
    var progress: Double?
    var mbps: Double?
    var gwMs: Double?
    var inetMs: Double?

    enum CodingKeys: String, CodingKey {
        case t, name, state, phases, mode, rc, ms, why, exit, stage, progress, mbps
        case gwMs = "gw_ms"
        case inetMs = "inet_ms"
    }
}

// Lenient throughout, in an extension so the memberwise initializer
// survives — the same discipline as `RunSnapshot`, for the same reason. A
// progress event that arrived with one surprising field must degrade to a
// missing detail, never to a dropped event: dropping a `done` leaves a row
// spinning until the run ends.
extension ProgressEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.lenient(.t, "")
        name = c.lenient(.name)
        state = c.lenient(.state)
        phases = c.lenient(.phases)
        mode = c.lenient(.mode)
        rc = c.lenient(.rc)
        ms = c.lenient(.ms)
        why = c.lenient(.why)
        exit = c.lenient(.exit)
        stage = c.lenient(.stage)
        progress = c.lenient(.progress)
        mbps = c.lenient(.mbps)
        gwMs = c.lenient(.gwMs)
        inetMs = c.lenient(.inetMs)
    }
}
