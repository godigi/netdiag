import Foundation

enum NetdiagError: LocalizedError {
    case binaryNotFound
    case scriptError(String)
    case badJSON(String)
    case cancelled
    /// `--show` could not resolve that id. Not a failure of the tool: the
    /// run store rolls over into an archive and is eventually pruned, so a
    /// list held in memory can outlive a record on disk.
    case runNotFound

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:      return BinaryLocator.missingBinaryMessage
        // Exit 3 is the CLI's "the script itself broke" status, deliberately
        // distinct from 1 and 2, which are verdicts about the network. Say
        // so rather than dressing a tool failure up as a diagnosis.
        case .scriptError(let s):  return "netdiag couldn't complete the check: \(s)"
        case .badJSON(let s):      return "netdiag returned something unreadable: \(s)"
        case .cancelled:           return "Check cancelled."
        case .runNotFound:         return "That check is no longer in your history — it may have been pruned."
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
/// `--json` still only emits at the very end of a run — that is acceptance
/// criterion 2, `netdiag --json | jq .`, and it is why there is no partial
/// result to stream. What *does* stream is the fd-3 progress protocol from
/// `docs/design/watching-it-happen.md`: the CLI points fd 3 at stderr under
/// `--progress` and announces a plan and one event per phase, which this
/// file parses as it arrives and hands to a `ScanProgress`.
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
        /// One question, answered on its own: `--speed-only`. Its record is
        /// a *measurement*, not an opinion about the network's health, so
        /// the caller must not adopt it as the current report — see Part B
        /// of docs/design/watching-it-happen.md.
        case speedOnly

        var arguments: [String] {
            switch self {
            case .full:           return ["--json", "--no-gping"]
            case .quick:          return ["--json", "--no-gping", "--quick"]
            case .alertTriggered: return ["--json", "--no-gping", "--no-bufferbloat", "--no-speed"]
            case .speedOnly:      return ["--json", "--no-gping", "--speed-only"]
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
            case .speedOnly:      return "about 30 seconds"
            }
        }
    }

    /// Run and decode, reporting progress as it happens.
    ///
    /// Cancellation terminates the child: a scan the user abandoned must not
    /// go on saturating the link, and must not go on holding the monitor
    /// paused.
    static func run(depth: Depth, target: String? = nil,
                    extraArguments: [String] = [],
                    progress: ScanProgress? = nil) async throws -> RunResult {
        var args = depth.arguments + extraArguments
        if let target, !target.isEmpty { args.append(target) }

        // Ordering matters, so events go through an AsyncStream rather than
        // one hop-to-the-main-actor Task per line. The stream buffers FIFO;
        // a task per line does not, and a `done` overtaking its `start`
        // leaves a finished phase rendered as running.
        var continuation: AsyncStream<String>.Continuation?
        var pump: Task<Void, Never>?
        if let progress, await supportsProgress() {
            args.append("--progress")
            let (stream, sink) = AsyncStream.makeStream(of: String.self)
            continuation = sink
            pump = Task { @MainActor in
                for await line in stream { progress.ingest(line: line) }
            }
        }

        let started = Date()
        let (out, _, status) = try await execute(arguments: args,
                                                 stderrLines: continuation)
        // Every event is applied before the caller sees the result, so the
        // view never renders a finished run over a half-filled phase list.
        await pump?.value

        // Cancelling terminates the child, which returns here as an
        // ordinary signal status with no JSON on stdout. Saying so as
        // `CancellationError` is what lets the coordinator tell "the user
        // pressed Cancel" apart from "netdiag emitted garbage".
        try Task.checkCancellation()

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

    /// Does the installed CLI understand `--progress`?
    ///
    /// Asked because the app bundle and the CLI are installed separately —
    /// `BinaryLocator` resolves whatever `netdiag` is on the machine, which
    /// may be older than this build. `bin/netdiag` answers an unknown flag
    /// with exit 3, so sending it unconditionally would turn every scan on
    /// such a machine into "netdiag couldn't complete the check".
    ///
    /// `--progress --help` rather than grepping the help text: the flag is
    /// machine-facing and may reasonably go undocumented, but a version that
    /// parses it exits 0 and a version that doesn't exits 3. Costs one
    /// process, once, for the life of the app.
    private static func supportsProgress() async -> Bool {
        await ProgressSupport.shared.value {
            guard let (_, _, status) = try? await execute(
                arguments: ["--progress", "--help"]) else { return false }
            return status == 0
        }
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

    /// `netdiag --show=<id>`, decoded, with the bytes kept alongside.
    ///
    /// Exit 3 is read here as "that id is gone". The CLI uses 3 for both a
    /// malformed argument and an unknown id, and the two cannot be told
    /// apart from the status alone — but the app only ever passes back an
    /// id that `--history` handed it, so the malformed branch is
    /// unreachable from the UI while the pruned one is reached by simply
    /// leaving the window open long enough.
    static func show(id: String) async throws -> RunDetail {
        let (out, _, status) = try await execute(arguments: ["--show=\(id)"])
        if status == 3 { throw NetdiagError.runNotFound }
        if status != 0 { throw NetdiagError.scriptError(String(out.prefix(400))) }
        guard let data = out.data(using: .utf8),
              var detail = try? JSONDecoder().decode(RunDetail.self, from: data) else {
            throw NetdiagError.badJSON(String(out.prefix(200)))
        }
        detail.rawJSON = out
        return detail
    }

    // MARK: - Process plumbing

    /// One child process, awaited. Returns (stdout, stderr, exit status).
    ///
    /// stdout and stderr are drained on background queues rather than read
    /// after `waitUntilExit`: netdiag can emit a few hundred KB of JSON,
    /// which is more than a pipe buffer holds, and reading afterwards
    /// deadlocks the moment it is.
    ///
    /// `stderrLines` reuses that same drain rather than adding a reader.
    /// Progress that arrived only after `waitUntilExit` would be a list of
    /// results for a run that had already finished — the moment progress
    /// stops being progress.
    private static func execute(
        arguments: [String],
        stderrLines: AsyncStream<String>.Continuation? = nil
    ) async throws -> (String, String, Int32) {
        guard let binary = BinaryLocator.resolve() else { throw NetdiagError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = BinaryLocator.environment()

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        let splitter = stderrLines.map { sink in
            LineSplitter { line in _ = sink.yield(line) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { collector.appendOut(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                collector.appendErr(d)
                splitter?.feed(d)
            }
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
                    let tail = errPipe.fileHandleForReading.availableData
                    collector.appendErr(tail)
                    splitter?.feed(tail)
                    // The final `run done` event can land in that tail, so
                    // flush before closing: a consumer that never sees it
                    // is a consumer whose phase rows never stop spinning.
                    splitter?.flush()
                    stderrLines?.finish()
                    continuation.resume(returning: (collector.stdoutString,
                                                    collector.stderrString,
                                                    proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    stderrLines?.finish()
                    continuation.resume(throwing: NetdiagError.scriptError(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Remembers one answer for the life of the process.
///
/// An actor rather than a `static var` because `supportsProgress()` can be
/// asked from two runs at once — the alert-triggered scan and a scan the
/// user started overlap by design — and two concurrent probes would spawn
/// two children to learn the same thing.
private actor ProgressSupport {
    static let shared = ProgressSupport()
    private var cached: Bool?

    func value(_ probe: @Sendable () async -> Bool) async -> Bool {
        if let cached { return cached }
        let answer = await probe()
        cached = answer
        return answer
    }
}

/// Reassembles whole lines from arbitrary pipe chunks.
///
/// A read boundary lands wherever the kernel puts it, so `{"t":"phase"` and
/// `,"state":"done"}` routinely arrive as two callbacks. Handing each chunk
/// to a JSON decoder would drop both halves of every event unlucky enough
/// to straddle one.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        lock.unlock()
        for line in lines { sink(line) }
    }

    /// The last line of a stream has no trailing newline to end it.
    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if let text = String(data: rest, encoding: .utf8), !text.isEmpty { sink(text) }
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
