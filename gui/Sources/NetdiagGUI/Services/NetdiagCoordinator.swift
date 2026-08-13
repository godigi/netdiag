import Foundation
import AppKit
import os

/// The one object that owns the others and decides when they act.
///
/// Everything stateful in this app is reachable from here, which keeps the
/// interesting question — *what causes what* — answerable by reading one
/// file rather than by tracing five observers.
@MainActor
@Observable
final class NetdiagCoordinator {

    let monitor = MonitorStream()
    let events = NetworkEventWatcher()
    let history = HistoryStore()
    let details = RunDetailStore()
    let alerts = AlertEngine()
    let watcher = WatcherControl()
    /// The observable face of `Defaults` — see `AppSettings`'s header.
    /// Owned here so one instance is shared by every view via the
    /// environment, instead of each view reading `Defaults` for itself.
    let appSettings = AppSettings()
    /// The run in flight, phase by phase. Reset at the start of every run
    /// and fed from the child's fd-3 stream as it arrives.
    let progress = ScanProgress()

    private(set) var latestRun: RunResult?
    /// Home's fallback for a session that has not run a scan yet.
    /// See `reportSource` for why this is a separate property rather than
    /// a second way to set `latestRun`, and `hydrateFromHistoryIfNeeded`
    /// for how it gets populated.
    private(set) var hydratedReport: RunDetail?
    private(set) var isScanning = false
    private(set) var scanStartedAt: Date?
    private(set) var scanKind: String = ""
    private(set) var lastRunError: String?
    /// The last `--speed-only` result, kept apart from `latestRun`. A speed
    /// test measures one thing and diagnoses nothing, so letting it become
    /// the current report would replace a full diagnosis with a card that
    /// has no verdict on it — Part B of the spec, in the app's own terms.
    private(set) var latestSpeedTest: RunSnapshot.Speedtest?
    private(set) var latestSpeedTestAt: Date?
    /// A section (or a stored run) another surface has asked the main
    /// window to show. Consumed by `MainWindow`, which may not exist yet at
    /// the moment of asking — see `consumeRequestedDestination()`.
    var requestedDestination: MainDestination?
    /// Set while a scan started *by an alert* is in flight. The loop guard:
    /// a scan started this way must never start another. Without it, a
    /// scan's own bufferbloat and speed phases can raise the very alert
    /// that triggers the next scan, forever.
    private(set) var scanWasAlertTriggered = false

    private var scanTask: Task<Void, Never>?
    private var lastNetworkID: String?
    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "coordinator")

    // MARK: - Lifecycle

    func start() {
        alerts.inNetworkGracePeriod = { [weak events] in
            events?.withinGracePeriod() ?? false
        }
        alerts.onAlertFired = { [weak self] def in
            self?.handleAlertFired(def)
        }
        monitor.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        events.onEvent = { [weak self] event in
            self?.handleNetworkEvent(event)
        }

        events.start()
        observeWorkspace()
        // Reap the monitor on quit. Without this the child is re-parented
        // to launchd and goes on pinging the gateway every ten seconds
        // after the app is gone — the exact misbehaviour that gets an
        // always-on app uninstalled.
        NotificationCenter.default.addObserver(
            forName: .netdiagWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        Task {
            await alerts.refreshAuthorization()
            await watcher.refresh()
            await history.load()
            await hydrateFromHistoryIfNeeded()
        }
        if Defaults.monitoringEnabled { monitor.start() }
    }

    func stop() {
        scanTask?.cancel()
        monitor.stop()
        events.stop()
    }

    // MARK: - Cold-launch hydration
    //
    // Home used to render nothing until the first scan of the session
    // finished, even on a machine with ~2,000 runs already in
    // `~/net-diag`. This fills that gap once, right after launch, without
    // ever letting the fallback be mistaken for a live measurement.

    /// Picks the newest run that counts as a check
    /// (`HistoryDocument.Run.isCheck` — the `run_mode` predicate
    /// docs/JSON-SCHEMA.md documents and `helpers/history.py` applies
    /// identically) and has an id `--show` can open, then fetches its full
    /// record via `details.detail(for:)`.
    ///
    /// Silent on failure: a pruned run (the store rolls into an archive and
    /// is eventually trimmed) or a `netdiag` older than `--show` must fall
    /// back to the ordinary empty state, not an error banner for something
    /// the user never asked to happen. Called once, from `start()`, before
    /// any scan can plausibly have finished — but if one lands anyway while
    /// the `await` below is in flight, the assignment after it is
    /// deliberately not re-guarded: `reportSource` prefers `.live`
    /// regardless of which of the two was written last, so a hydrated
    /// report landing a moment after a real one is inert, not a race worth
    /// closing.
    private func hydrateFromHistoryIfNeeded() async {
        guard latestRun == nil, hydratedReport == nil else { return }
        // `recentChecks(limit: 1)`, not a larger buffer: a `netdiag` new
        // enough to stamp run ids stamps every run, so the newest already
        // has one; one old enough not to stamps none, and no larger limit
        // would find one either.
        guard let id = history.recentChecks(limit: 1).compactMap(\.runID).first else { return }
        do {
            hydratedReport = try await details.detail(for: id)
        } catch {
            log.debug("cold-launch hydration skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Monitoring toggle

    func setMonitoring(enabled: Bool) {
        Defaults.monitoringEnabled = enabled
        alerts.monitoringPaused = !enabled
        if enabled { monitor.start() } else { monitor.stop() }
    }

    /// Apply changed cadence settings. A restart rather than a signal,
    /// because the intervals are command-line arguments — the process has
    /// no way to be told about new ones.
    func applyCadenceSettings() {
        guard Defaults.monitoringEnabled, monitor.isRunning else { return }
        monitor.restart()
    }

    // MARK: - Samples

    private func handleSample(_ sample: MonitorSample) {
        alerts.evaluate(sample: sample)

        guard let id = sample.network.id, !id.isEmpty else { return }
        guard id != lastNetworkID else { return }
        lastNetworkID = id
        alerts.networkChanged(to: id)
        log.info("now on network \(id, privacy: .public)")

        // First time this app has seen this network: run one scan, so the
        // dashboard has something real the moment the user opens it. Keyed
        // on a set the app owns rather than on the history, because the
        // history only learns about the network *from* this scan — reading
        // it here would fire the trigger a second time.
        guard Defaults.scanOnNewNetwork else { return }
        var seen = Defaults.seenNetworks
        guard !seen.contains(id) else { return }
        seen.insert(id)
        Defaults.seenNetworks = seen
        log.info("first sighting of \(id, privacy: .public) — scanning")
        runScan(depth: .quick, reason: "new network")
    }

    private func handleNetworkEvent(_ event: NetworkEventWatcher.Event) {
        // CoreWLAN and NWPathMonitor are near-instant where the monitor
        // loop is up to a cadence behind. The monitor is the fallback, not
        // the primary detector — so nudge it to resample now rather than
        // letting the flag and public IP sit stale for ten seconds.
        if case .pathChanged(let satisfied, _) = event, !satisfied { return }
        log.debug("network event — refreshing history")
        Task { await history.load() }
    }

    // MARK: - Scans

    func runScan(depth: NetdiagRunner.Depth, reason: String, target: String? = nil) {
        launch(depth: depth, reason: reason, target: target, adoptAsReport: true)
    }

    /// The dropdown's "Speed test": `--speed-only`, with the same live
    /// progress a full scan shows.
    ///
    /// `adoptAsReport: false` is the whole difference. A speed-only run
    /// carries a measurement and no diagnosis, so it neither replaces the
    /// report card nor reaches the alert engine — a fast link is not
    /// evidence that nothing is wrong.
    func runSpeedTest() {
        launch(depth: .speedOnly, reason: "speed test", target: nil, adoptAsReport: false)
    }

    private func launch(depth: NetdiagRunner.Depth, reason: String,
                        target: String?, adoptAsReport: Bool) {
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return
        }
        isScanning = true
        scanStartedAt = Date()
        scanKind = reason
        lastRunError = nil
        progress.reset()

        // Both halves matter. Pausing the monitor keeps the scan's speed
        // test and bufferbloat probe from poisoning the samples and
        // flipping the cadence to "degraded"; holding alerts keeps the app
        // from notifying about latency it caused itself. And the scan's own
        // loss probe needs a quiet link — the same constraint that forbids
        // parallelising it with bufferbloat inside the CLI.
        //
        // The pause is SIGUSR1, not SIGSTOP. See MonitorStream for why the
        // obvious mechanism kills the process 2 s in.
        monitor.pause(reason: "a check is running")
        alerts.scanInProgress = true

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanning = false
                self.scanStartedAt = nil
                self.scanWasAlertTriggered = false
                self.alerts.scanInProgress = false
                self.monitor.resume(reason: "a check is running")
                // Whatever happened — a clean exit, a crash, Cancel — the
                // child is gone, so no phase can report again. Without this
                // a cancelled run leaves its rows spinning forever.
                self.progress.processEnded(exit: nil)
            }
            do {
                let result = try await NetdiagRunner.run(depth: depth, target: target,
                                                         progress: self.progress)
                guard !Task.isCancelled else { return }
                if adoptAsReport {
                    self.latestRun = result
                    // Not required for correctness — `reportSource` prefers
                    // `.live` no matter which of the two was written last,
                    // so a stale `hydratedReport` left in place would never
                    // render again regardless. This is about memory: a
                    // `RunDetail` carries `rawJSON`, the full `--show`
                    // response, and there is no reason to keep holding that
                    // once nothing can display it.
                    self.hydratedReport = nil
                    self.alerts.evaluate(run: result.snapshot)
                } else {
                    self.latestSpeedTest = result.snapshot.speedtest
                    self.latestSpeedTestAt = Date()
                }
                // The run appended itself to baseline.jsonl, so the charts
                // and the network list are one record out of date until
                // this reload.
                await self.history.load()
                self.log.info("\(reason, privacy: .public) finished in \(result.duration, format: .fixed(precision: 1))s, exit \(result.exitCode)")
            } catch is CancellationError {
                self.log.debug("scan cancelled")
            } catch {
                self.lastRunError = error.localizedDescription
                self.log.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Latency test

    /// The dropdown's "Latency test". Deliberately not a check: it asks the
    /// monitor already running to sample faster for a minute and shows the
    /// result live. Spawning a second `netdiag --monitor` would put two
    /// probers on the link one of them is trying to measure.
    func startLatencyTest() {
        requestedDestination = .live
        guard Defaults.monitoringEnabled, monitor.isRunning else {
            // The Live section explains the off state itself, which is why
            // this still opens it rather than silently doing nothing.
            log.debug("latency test asked for while monitoring is off")
            return
        }
        monitor.beginBurst(interval: Defaults.latencyTestInterval,
                           duration: Defaults.latencyTestDuration)
    }

    func stopLatencyTest() { monitor.endBurst() }

    func consumeRequestedDestination() -> MainDestination? {
        defer { requestedDestination = nil }
        return requestedDestination
    }

    /// An alert fired. Run a scan so the notification can be replaced with
    /// the CLI's own explanation — that in-place update is the entire point
    /// of the trigger.
    private func handleAlertFired(_ def: AlertDefinition) {
        guard Defaults.scanOnAlert else { return }
        // Loop guard, two clauses. A scan started by an alert never starts
        // another, and no scan starts while one is running. Between them
        // there is no path from "alert fires" back to "alert fires".
        guard !scanWasAlertTriggered, !isScanning else {
            log.debug("loop guard: not scanning for \(def.id, privacy: .public)")
            return
        }
        scanWasAlertTriggered = true
        // .alertTriggered skips bufferbloat and the speed test. Both
        // deliberately saturate the link, and running a load test on a
        // connection that is *already* failing makes the user's situation
        // worse in the middle of whatever broke.
        runScan(depth: .alertTriggered, reason: "checking \(def.title.lowercased())")
    }

    // MARK: - Power

    /// Display sleep and battery, from NSWorkspace. These events arrive
    /// here for free; asking bash to poll pmset for the same information
    /// would cost a process spawn per cycle, forever. Energy is the main UX
    /// risk of an always-on app, and this is where the awareness belongs.
    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard Defaults.pauseOnDisplaySleep else { return }
                self?.monitor.pause(reason: "the display is asleep")
                self?.alerts.monitoringPaused = true
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.resume(reason: "the display is asleep")
                self?.alerts.monitoringPaused = self?.monitor.isPausedForAnyReason ?? false
            }
        }
        // System sleep pauses regardless of the display-sleep preference:
        // the machine is going away, and a frozen child is what makes the
        // wake instantaneous instead of costing a fresh bash startup.
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.pause(reason: "your Mac is asleep")
                self?.alerts.monitoringPaused = true
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.resume(reason: "your Mac is asleep")
                self?.alerts.monitoringPaused = self?.monitor.isPausedForAnyReason ?? false
                // The world may be entirely different after a wake, and
                // the monitor's own timers do not know that.
                await self?.history.load()
            }
        }
    }

    // MARK: - Sharing

    /// `netdiag --redact --json` on the clipboard. Built for the case it
    /// was written for: a non-technical user pasting into an ISP support
    /// chat without handing over their public IP, SSID, gateway MAC or
    /// city. Runs the CLI rather than re-encoding the snapshot on screen,
    /// because redaction is defined once in helpers/emit_json.py and a
    /// second implementation here is a second thing that can leak.
    func copyShareableReport() async -> Bool {
        do {
            let report = try await NetdiagRunner.redactedReport(depth: .quick)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            return true
        } catch {
            lastRunError = error.localizedDescription
            return false
        }
    }

    // MARK: - Presentation helpers

    /// What `HomeView` has to render: either the run that finished in
    /// this session, or a historical one fetched to fill the screen before
    /// any scan has run this launch. See `reportSource` for how the choice
    /// between the two is made and what it does and doesn't mean.
    enum ReportSource {
        case live(RunResult)
        case stored(RunDetail)
    }

    /// `.live` always wins: `launch()` clears `hydratedReport` the moment a
    /// scan lands, and this checks `latestRun` first regardless, so the two
    /// can never be shown in the wrong order even if that clear were ever
    /// missed.
    ///
    /// Deliberately not read by `currentHealth`, `headline`, or the alert
    /// engine — all three read `latestRun` directly, unaffected by this
    /// property's existence. A hydrated report is a *display* fallback for
    /// a screen that would otherwise be empty; it is not a fresh
    /// measurement, and nothing that judges the network's current state is
    /// allowed to treat it as one.
    var reportSource: ReportSource? {
        if let latestRun { return .live(latestRun) }
        if let hydratedReport { return .stored(hydratedReport) }
        return nil
    }

    var currentHealth: Health {
        if let sample = monitor.latest { return sample.health }
        if let run = latestRun { return run.snapshot.worstSeverity }
        return .healthy
    }

    /// The one sentence the dropdown leads with.
    ///
    /// Every branch here either states an observable fact about the app's
    /// own state ("Monitoring is off") or hands back prose the CLI wrote.
    /// The healthy line is the only exception, and it is the CLI's own
    /// wording from lib/diagnosis.sh's `ok()` branch.
    var headline: String {
        if !Defaults.monitoringEnabled { return "Monitoring is off." }
        if let alert = alerts.activeSorted.first {
            return alert.body.isEmpty ? alert.title : alert.body
        }
        if let cause = latestRun?.snapshot.mostLikelyRootCause, !cause.isEmpty {
            return cause
        }
        if let sample = monitor.latest, !sample.link.up {
            return "Your Mac has no network connection at all."
        }
        if monitor.latest == nil && latestRun == nil { return "Starting up…" }
        return "Nothing obviously wrong — your network looks healthy."
    }
}
