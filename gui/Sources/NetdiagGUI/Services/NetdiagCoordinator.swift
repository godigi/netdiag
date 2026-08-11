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
    let alerts = AlertEngine()
    let watcher = WatcherControl()

    private(set) var latestRun: RunResult?
    private(set) var isScanning = false
    private(set) var scanStartedAt: Date?
    private(set) var scanKind: String = ""
    private(set) var lastRunError: String?
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
        }
        if Defaults.monitoringEnabled { monitor.start() }
    }

    func stop() {
        scanTask?.cancel()
        monitor.stop()
        events.stop()
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
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return
        }
        isScanning = true
        scanStartedAt = Date()
        scanKind = reason
        lastRunError = nil

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
            }
            do {
                let result = try await NetdiagRunner.run(depth: depth, target: target)
                guard !Task.isCancelled else { return }
                self.latestRun = result
                self.alerts.evaluate(run: result.snapshot)
                // The run appended itself to baseline.jsonl, so the charts
                // and the network list are one record out of date until
                // this reload.
                await self.history.load()
                self.log.info("scan finished in \(result.duration, format: .fixed(precision: 1))s, exit \(result.exitCode)")
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
