import Foundation
import os

/// Owns the long-lived `netdiag --monitor` child: spawns it, reads stdout
/// line by line into an `AsyncStream`, restarts it with backoff if it dies,
/// and pauses it with SIGUSR1/SIGUSR2.
///
/// ── Why pause rather than kill ─────────────────────────────────────────
/// A pause suspends probing without losing the process, so it costs nothing
/// and a resume loses nothing. Killing and respawning would pay ~1 s of
/// bash startup plus a full probe cycle each time, and the three things
/// that pause the monitor — display sleep, low battery, and a scan in
/// progress — all happen often enough for that to matter.
///
/// ── Why not SIGSTOP ────────────────────────────────────────────────────
/// SIGSTOP was the obvious mechanism and it is actively unsafe here. POSIX
/// sends SIGHUP followed by SIGCONT to a process group that becomes newly
/// orphaned while any member is stopped. A stopped monitor still has live
/// children — the two-second gateway ping, with_timeout's killer subshells
/// — and the moment one exits, the group orphans and the SIGHUP kills it.
///
/// Measured, not theorised: under this app as parent the monitor died
/// 2.1 s into every pause, exactly one ping probe's length, and the app
/// dutifully restarted it *during the scan the pause existed to protect*.
/// It never reproduced from a terminal, because a controlling terminal
/// keeps the group non-orphaned — which is exactly how it would have
/// shipped. lib/monitor.sh now traps SIGUSR1/SIGUSR2 and suspends its own
/// probing instead.
///
/// ── Why a scan pauses it ───────────────────────────────────────────────
/// This is not politeness. A full scan runs a speed test that deliberately
/// saturates the link and a bufferbloat probe that does the same; samples
/// taken during either would show invented latency and loss, flip the
/// monitor into its 5-second "degraded" cadence, and could fire a WiFi
/// alert *caused by the app's own traffic*. The scan's own loss probe needs
/// a quiet link too — the same constraint that forbids parallelising it
/// with bufferbloat inside the CLI.
@MainActor
@Observable
final class MonitorStream {

    private(set) var latest: MonitorSample?
    private(set) var isRunning = false
    private(set) var isPaused = false
    /// Why it is paused, for the dropdown's status line. The user should
    /// never see a stopped indicator with no explanation.
    private(set) var pauseReason: String?
    private(set) var lastError: String?
    /// Rolling window for the expert layer's sparklines. Bounded because
    /// this process runs for days: at the 10 s cadence 360 samples is an
    /// hour, which is as far back as a live sparkline is worth reading.
    private(set) var recent: [MonitorSample] = []

    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var pauseHolders: Set<String> = []

    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "monitor")
    private static let recentCapacity = 360

    /// Called for every decoded sample. The alert engine subscribes here.
    var onSample: ((MonitorSample) -> Void)?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard let binary = BinaryLocator.resolve() else {
            lastError = BinaryLocator.missingBinaryMessage
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "--monitor",
            "--monitor-fast-interval",     String(Defaults.fastInterval),
            "--monitor-degraded-interval", String(Defaults.degradedInterval),
            "--monitor-medium-interval",   String(Defaults.mediumInterval),
            "--monitor-slow-interval",     String(Defaults.slowInterval),
        ]
        proc.environment = BinaryLocator.environment()

        let pipe = Pipe()
        proc.standardOutput = pipe
        // stderr goes nowhere: the monitor writes progress and warnings
        // there, and an unread pipe that fills would block the child
        // forever. /dev/null is the only safe choice for a process meant to
        // run for days.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastError = "Couldn't start monitoring: \(error.localizedDescription)"
            scheduleRestart()
            return
        }

        process = proc
        isRunning = true
        isPaused = false
        lastError = nil
        log.info("monitor started, pid \(proc.processIdentifier)")

        readTask = Task { [weak self] in
            await self?.consume(pipe: pipe, process: proc)
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let process, process.isRunning {
            // Resume first: a paused monitor handles SIGTERM promptly
            // either way, but leaving it paused-then-terminated makes the
            // shutdown path depend on trap ordering for no benefit.
            kill(process.processIdentifier, SIGUSR2)
            process.terminate()
        }
        process = nil
        isRunning = false
        isPaused = false
        pauseHolders.removeAll()
        pauseReason = nil
    }

    func restart() {
        stop()
        restartAttempts = 0
        start()
    }

    // MARK: - Pause / resume
    //
    // Reference-counted by reason, because the holders overlap: a scan
    // started from the dropdown while the display sleeps would otherwise
    // have whichever finished first resume the monitor while the other was
    // still relying on it being paused.

    func pause(reason: String) {
        pauseHolders.insert(reason)
        pauseReason = pauseHolders.sorted().joined(separator: ", ")
        guard let process, process.isRunning, !isPaused else { return }
        kill(process.processIdentifier, SIGUSR1)
        isPaused = true
        log.debug("monitor paused: \(reason, privacy: .public)")
    }

    func resume(reason: String) {
        pauseHolders.remove(reason)
        guard pauseHolders.isEmpty else {
            pauseReason = pauseHolders.sorted().joined(separator: ", ")
            return
        }
        pauseReason = nil
        guard let process, process.isRunning, isPaused else { return }
        kill(process.processIdentifier, SIGUSR2)
        isPaused = false
        log.debug("monitor resumed")
    }

    var isPausedForAnyReason: Bool { !pauseHolders.isEmpty }

    // MARK: - Reading

    /// Reads the pipe on a detached task and hands whole lines back to the
    /// main actor. `bytes.lines` handles the framing; the monitor flushes
    /// after every sample so a line arrives as soon as it is written rather
    /// than when a 4 KB buffer fills.
    private func consume(pipe: Pipe, process proc: Process) async {
        let handle = pipe.fileHandleForReading
        do {
            for try await line in handle.bytes.lines {
                if Task.isCancelled { return }
                guard let data = line.data(using: .utf8) else { continue }
                guard let sample = try? JSONDecoder().decode(MonitorSample.self, from: data) else {
                    // One malformed line must not end the session. Log and
                    // keep reading: the next sample is 10 seconds away and
                    // is probably fine.
                    log.error("undecodable monitor line: \(line.prefix(200), privacy: .public)")
                    continue
                }
                ingest(sample)
            }
        } catch {
            log.error("monitor read failed: \(error.localizedDescription, privacy: .public)")
        }
        // Falling out of the loop means EOF: the child exited.
        if !Task.isCancelled {
            isRunning = false
            log.info("monitor exited status=\(proc.terminationStatus) reason=\(proc.terminationReason == .uncaughtSignal ? "signal" : "exit", privacy: .public)")
            scheduleRestart()
        }
    }

    private func ingest(_ sample: MonitorSample) {
        // A sample proves the process is alive and producing, which is the
        // only evidence that matters for backoff.
        restartAttempts = 0
        latest = sample
        recent.append(sample)
        if recent.count > Self.recentCapacity {
            recent.removeFirst(recent.count - Self.recentCapacity)
        }
        onSample?(sample)
    }

    /// Exponential backoff, capped. An unbounded retry loop against a
    /// binary that has been deleted or a bash that has been uninstalled
    /// would spawn a process per second forever — visible in Activity
    /// Monitor as exactly the kind of misbehaviour that gets an always-on
    /// app switched off.
    private func scheduleRestart() {
        guard Defaults.monitoringEnabled else { return }
        restartAttempts += 1
        let delay = min(pow(2.0, Double(min(restartAttempts, 6))), 60.0)
        log.info("restarting monitor in \(delay, format: .fixed(precision: 0))s (attempt \(self.restartAttempts))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, Defaults.monitoringEnabled else { return }
            self.start()
        }
    }
}
