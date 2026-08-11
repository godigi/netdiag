import Foundation

enum NetdiagError: LocalizedError {
    case binaryNotFound
    case scriptError(String)
    case badJSON(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:      return BinaryLocator.missingBinaryMessage
        // Exit 3 is the CLI's "the script itself broke" status, deliberately
        // distinct from 1 and 2, which are verdicts about the network. Say
        // so rather than dressing a tool failure up as a diagnosis.
        case .scriptError(let s):  return "netdiag couldn't complete the check: \(s)"
        case .badJSON(let s):      return "netdiag returned something unreadable: \(s)"
        case .cancelled:           return "Check cancelled."
        }
    }
}

/// Runs `netdiag --json` and decodes the result.
///
/// A plain async function returning a value, not an actor holding state:
/// the concurrency hazard around `Process` is shared mutable state, and a
/// function that owns its process for the length of one call and hands back
/// an immutable result has none.
///
/// `--json` only emits at the very end of a run, so there is no partial
/// output to stream and therefore no meaningful progress percentage. The UI
/// shows an indeterminate spinner with an elapsed timer, and offers
/// `--quick` (~8 s) beside the full run (~30 s without the speed test,
/// ~65-115 s with it, depending on which speedtest CLI is installed).
struct NetdiagRunner {

    enum Depth {
        /// Everything. Slow, and the only mode that produces bufferbloat,
        /// MTU, per-hop loss and a speed test.
        case full
        /// The CLI's --quick: skips bufferbloat, mtr, the speed test, the
        /// internet loss probe, the baseline diff and the WiFi scan.
        case quick
        /// What an alert triggers. Full depth *minus* bufferbloat, which
        /// deliberately saturates the link — running a load test on a
        /// connection that is already failing makes the user's situation
        /// worse in the middle of whatever they were doing.
        case alertTriggered

        var arguments: [String] {
            switch self {
            case .full:           return ["--json", "--no-gping"]
            case .quick:          return ["--json", "--no-gping", "--quick"]
            case .alertTriggered: return ["--json", "--no-gping", "--no-bufferbloat", "--no-speed"]
            }
        }

        /// Rough wall-clock, for the "this usually takes about…" line. An
        /// honest estimate beats a fake progress bar; the CLI's own budget
        /// is 30 s full / 8 s quick and it measures itself against it.
        var estimate: String {
            switch self {
            case .full:           return "about a minute"
            case .quick:          return "about 10 seconds"
            case .alertTriggered: return "about 30 seconds"
            }
        }
    }

    /// Run and decode. Cancellation terminates the child: a scan the user
    /// abandoned must not go on saturating the link, and must not go on
    /// holding the monitor paused.
    static func run(depth: Depth, target: String? = nil,
                    extraArguments: [String] = []) async throws -> RunResult {
        var args = depth.arguments + extraArguments
        if let target, !target.isEmpty { args.append(target) }
        let started = Date()
        let (out, _, status) = try await execute(arguments: args)

        if status == 3 {
            throw NetdiagError.scriptError(out.isEmpty ? "exit status 3" : String(out.prefix(400)))
        }
        guard let data = out.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(RunSnapshot.self, from: data) else {
            throw NetdiagError.badJSON(String(out.prefix(200)))
        }
        return RunResult(snapshot: snapshot, rawJSON: out, exitCode: status,
                         startedAt: started, finishedAt: Date())
    }

    /// `netdiag --redact --json`, for "Copy shareable report". The point of
    /// running the CLI again rather than re-encoding the snapshot already
    /// on screen: redaction is defined in helpers/emit_json.py, and a
    /// second implementation in Swift is a second thing that can leak.
    static func redactedReport(depth: Depth = .quick) async throws -> String {
        let (out, _, status) = try await execute(
            arguments: depth.arguments + ["--redact"])
        if status == 3 { throw NetdiagError.scriptError(String(out.prefix(400))) }
        return out
    }

    /// `netdiag --history`, decoded.
    static func history(limit: Int = 0) async throws -> HistoryDocument {
        let arg = limit > 0 ? "--history=\(limit)" : "--history"
        let (out, _, status) = try await execute(arguments: [arg])
        if status != 0 { throw NetdiagError.scriptError(String(out.prefix(400))) }
        guard let data = out.data(using: .utf8),
              let doc = try? JSONDecoder().decode(HistoryDocument.self, from: data) else {
            throw NetdiagError.badJSON(String(out.prefix(200)))
        }
        return doc
    }

    // MARK: - Process plumbing

    /// One child process, awaited. Returns (stdout, stderr, exit status).
    ///
    /// stdout and stderr are drained on background queues rather than read
    /// after `waitUntilExit`: netdiag can emit a few hundred KB of JSON,
    /// which is more than a pipe buffer holds, and reading afterwards
    /// deadlocks the moment it is.
    private static func execute(arguments: [String]) async throws -> (String, String, Int32) {
        guard let binary = BinaryLocator.resolve() else { throw NetdiagError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = BinaryLocator.environment()

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { collector.appendOut(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { collector.appendErr(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    // Whatever landed between the last readability callback
                    // and exit. Without this the tail of a large JSON body
                    // is silently truncated and the decode fails on a run
                    // that actually succeeded.
                    collector.appendOut(outPipe.fileHandleForReading.availableData)
                    collector.appendErr(errPipe.fileHandleForReading.availableData)
                    continuation.resume(returning: (collector.stdoutString,
                                                    collector.stderrString,
                                                    proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NetdiagError.scriptError(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// A tiny lock-guarded buffer. `readabilityHandler` fires on an arbitrary
/// queue, so appending to a plain `Data` from it is a data race even in
/// Swift 5 mode — the kind that shows up as a truncated report once a week
/// rather than as a crash.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }

    var stdoutString: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }
    var stderrString: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}
