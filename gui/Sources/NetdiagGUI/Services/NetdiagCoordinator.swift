import Foundation
import AppKit
import CoreWLAN
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
    /// The CLI's rules catalog — see that store's header for why it's
    /// `@Observable` rather than an actor like `CapabilityStore`. Every
    /// `RuleChip` and every category-driven report row reads
    /// `rulesCatalog.catalog` directly rather than awaiting anything.
    let rulesCatalog = RulesCatalogStore()
    /// The CLI's Wi-Fi signal scale — see that store's header. Same
    /// synchronous-read shape as `rulesCatalog`: the Wi-Fi cell on Home and
    /// in the dropdown reads `signalScale.scale` directly from a view body.
    let signalScale = SignalScaleStore()
    /// The observable face of `Defaults` — see `AppSettings`'s header.
    /// Owned here so one instance is shared by every view via the
    /// environment, instead of each view reading `Defaults` for itself.
    let appSettings = AppSettings()
    /// Automated update checker against GitHub releases.
    let updateChecker = UpdateChecker()
    /// macOS Location Services permission manager.
    let locationPermissions = LocationPermissionStore()
    /// The run in flight, phase by phase. Reset at the start of every run
    /// and fed from the child's fd-3 stream as it arrives.
    let progress = ScanProgress()
    /// Durable history of CLI-reported changes (monitor `changes` entries
    /// and fired alerts) — the dropdown's timeline and its
    /// time-since-last-change headline both read this. Named `eventLog`
    /// rather than `events` because that name is already `events:
    /// NetworkEventWatcher` above, a different thing (CoreWLAN/NWPath
    /// notifications, not stored history).
    let eventLog = EventStore()

    private(set) var latestRun: RunResult?
    /// Home's fallback for a session that has not run a scan yet.
    /// See `reportSource` for why this is a separate property rather than
    /// a second way to set `latestRun`, and `hydrateFromHistoryIfNeeded`
    /// for how it gets populated.
    private(set) var hydratedReport: RunDetail?
    /// Live SSID read from CoreWLAN — the GUI's own source, not the CLI's.
    /// The bundled CLI reads the SSID via `ipconfig getsummary`, but TCC
    /// attributes that call to `/usr/sbin/ipconfig` rather than this .app,
    /// so a Location Services grant to netdiag unredacts the GUI's own
    /// CoreWLAN `ssid()` call but leaves the CLI's reading empty/redacted.
    /// Without this, a user who has granted Location sees "WiFi (SSID
    /// hidden by macOS)" in the dropdown even though the permission is
    /// live. Refreshed once per monitor sample (see `handleSample`) so a
    /// view body never pays for the CoreWLAN syscall.
    private(set) var liveSSID: String?
    private(set) var isScanning = false
    private(set) var scanStartedAt: Date?
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
    /// The severity seen on the previous sample, used by `handleSample` to
    /// detect the ok/info → warn/critical edge that auto-starts an
    /// investigation burst. Stored on the coordinator rather than read back
    /// from the monitor so the transition is exact even when a burst
    /// restart resets the monitor's own sample window.
    private var lastSeverity: String = "ok"
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
        // Its own task, not folded into the one above: the catalog gates
        // on a *different* capability (`rulesCatalog`, not `history`) and
        // has nothing to sequence after — chips and report rows render
        // fine before it resolves, they just show the inert fallback until
        // it does.
        rulesCatalog.ensureLoaded()
        // Same shape, same reasoning as rulesCatalog.ensureLoaded() above:
        // its own capability gate, nothing to sequence after.
        signalScale.ensureLoaded()
        // Events stored before the CLI phrased rule changes from the
        // catalog read "Issue G2 cleared". Rewrite them once the catalog
        // is in hand so an upgrade doesn't leave rule IDs in a timeline
        // whose whole point is plain language.
        Task { [weak self] in
            await self?.rulesCatalog.refresh()
            guard let self else { return }
            self.eventLog.rephraseLegacyRuleEvents { [weak self] ruleID in
                self?.rulesCatalog.catalog?[ruleID]?.title
            }
        }
        // Lets AlertEngine.activeSorted rank alerts by the CLI's own
        // severity instead of raise order — read live off the catalog each
        // call, so a rank asked for before the catalog resolves degrades to
        // 0 (raised-time order) rather than needing a second wiring step
        // once the fetch completes.
        alerts.severityRank = { [weak self] ruleID in
            switch self?.rulesCatalog.catalog?[ruleID]?.severity {
            case "critical": return 3
            case "warn", "warning": return 2
            case "info": return 1
            default: return 0
            }
        }
        if Defaults.monitoringEnabled { monitor.start() }

        // Check for updates daily in background after initial startup delay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.updateChecker.performDailyCheck()
        }
    }

    func stop() {
        scanTask?.cancel()
        monitor.stop()
        events.stop()
    }

    // MARK: - Window activation policy

    /// How many of the app's real `Window` scenes (dashboard, settings,
    /// onboarding) are currently on screen. The app ships as `LSUIElement`
    /// — no Dock icon, no app-switcher slot, which is right for an always-on
    /// menu-bar monitor. But a window the user opened on purpose should
    /// behave like a normal window while it is on screen: the policy flips
    /// to `.regular` the moment the first one appears (Dock icon + Cmd-Tab
    /// slot) and back to `.accessory` the instant the last one closes (Dock
    /// icon vanishes, menu-bar dot stays). Driven by `onAppear`/`onDisappear`
    /// on each window's root view rather than by `NSWindow` notifications,
    /// which fire unreliably for SwiftUI `Window` scenes and left the Dock
    /// icon stuck or the switcher slot missing.
    private var openWindowCount = 0

    func windowAppeared() {
        openWindowCount += 1
        applyActivationPolicy()
    }

    func windowDisappeared() {
        if openWindowCount > 0 { openWindowCount -= 1 }
        applyActivationPolicy()
    }

    private func applyActivationPolicy() {
        let regular = openWindowCount > 0
        NSApp?.setActivationPolicy(regular ? .regular : .accessory)
        // Activating on open is what makes the window arrive in front
        // rather than behind whatever was frontmost, and is also the nudge
        // the app switcher needs to pick up a policy that just changed to
        // `.regular` at runtime.
        if regular { NSApp?.activate(ignoringOtherApps: true) }
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
        if latestRun == nil, hydratedReport == nil {
            if let id = history.recentChecks(limit: 1).compactMap(\.runID).first {
                do {
                    hydratedReport = try await details.detail(for: id)
                } catch {
                    log.debug("cold-launch hydration skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if latestSpeedTest == nil {
            if let st = hydratedReport?.run.speedtest, st.downMbps != nil {
                latestSpeedTest = st
                latestSpeedTestAt = hydratedReport?.run.timestamp.flatMap { HistoryDocument.iso.date(from: $0) }
            } else if let speed = history.latestSpeedTest() {
                latestSpeedTest = RunSnapshot.Speedtest(downMbps: speed.down, upMbps: speed.up)
                latestSpeedTestAt = speed.date
            }
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
        refreshLiveWiFi()
        adoptLiveSSIDAsNameIfNeeded()
        alerts.evaluate(sample: sample)
        considerInvestigationBurst(sample)

        for change in sample.changes {
            eventLog.record(
                kind: change.kind,
                summary: change.summary,
                ruleID: change.field == "status.rules"
                    ? (change.to ?? change.from) : nil,
                date: sample.timestamp)
        }

        // The history group key, so `seenNetworks`, the alert engine's
        // per-network memory and the first-sighting scan all key on the
        // same id the Networks tab renders by — the raw sample id is the
        // record format, which never matches a history group.
        guard let id = sample.network.historyJoinID else { return }
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
        // The one automatic full check, and the reason there is no timed
        // one: joining a network for the first time is exactly when a
        // baseline of what it can do — throughput, bufferbloat, path MTU —
        // is worth having, and the `seenNetworks` guard above bounds it to
        // once per network for the life of the install. Monitoring covers
        // the continuous question; this covers the one-off one.
        runFullCheck(reason: "new network")
    }

    /// Auto-start a short, fast-cadence "investigation" burst the moment
    /// the CLI's verdict turns from ok/info to warn/critical — before an
    /// alert's dwell has elapsed and before any triggered scan lands. The
    /// user's mental model is that the app starts pinging constantly and
    /// fast the instant something looks wrong, and this is what delivers
    /// it: the monitor restarts at the 2 s latency-test floor for 60 s, so
    /// gateway and internet ping arrive every 2 s rather than every 5 s
    /// while the problem is being confirmed. After the burst, sustained
    /// degraded (3 s) takes over for as long as severity stays warn/
    /// critical — `MON_DEGRADED` follows severity in `lib/monitor.sh`'s
    /// `_mon_rules`. Fires only on the genuine ok/info → warn/critical
    /// edge, not on every warn/critical sample, so a sustained outage
    /// gets one surge at onset and a steady 3 s after, not a restart
    /// every minute. A burst already running is not re-triggered; a scan
    /// in progress blocks it (a scan pauses the monitor and saturates the
    /// link, and a burst's 2 s samples would be measuring the scan's own
    /// traffic); a paused or stopped monitor has nothing to burst.
    private func considerInvestigationBurst(_ sample: MonitorSample) {
        let sev = sample.status.severity
        defer { lastSeverity = sev }
        let turnedBad = (sev == "warn" || sev == "critical")
            && lastSeverity != "warn" && lastSeverity != "critical"
        guard turnedBad,
              !sample.status.paused,
              monitor.isRunning, !monitor.isPaused,
              !isScanning,
              !monitor.isBursting,
              Defaults.monitoringEnabled else { return }
        monitor.beginBurst(interval: Defaults.latencyTestInterval,
                           duration: Defaults.latencyTestDuration)
        log.info("severity turned \(sev, privacy: .public) — started 2s investigation burst")
    }

    private func handleNetworkEvent(_ event: NetworkEventWatcher.Event) {
        // CoreWLAN and NWPathMonitor are near-instant where the monitor
        // loop is up to a cadence behind. The monitor is the fallback, not
        // the primary detector — so nudge it to resample now rather than
        // letting the flag and public IP sit stale for ten seconds.
        if case .pathChanged(let satisfied, _) = event, !satisfied { return }
        log.debug("network event — refreshing history and forcing monitor refresh")
        monitor.forceRefresh()
        Task { await history.load() }
    }

    // MARK: - Scans

    func runScan(depth: NetdiagRunner.Depth, reason: String, target: String? = nil) {
        launch(depth: depth, reason: reason, target: target, adoptAsReport: true)
    }

    /// Whether the "Full check" action should be offered as runnable right
    /// now. Read by the views to disable the control and say why.
    var fullCheckIsSafe: Bool {
        FullCheckPolicy.isSafe(severity: monitor.latest?.status.severity ?? "")
    }

    /// The full battery: bufferbloat, the MTU probe, per-hop loss and a
    /// speed test — none of which any other depth produces, and all of
    /// which the Report card, the Trends charts and the dropdown's
    /// throughput cells are built to display.
    ///
    /// Refuses while the CLI's verdict is critical, and falls back to the
    /// alert-triggered depth instead of doing nothing: someone who pressed
    /// this button wants a check, and the lighter one is still worth
    /// running. See `FullCheckPolicy` for why bufferbloat is the specific
    /// hazard.
    func runFullCheck(reason: String = "you asked for a full check") {
        guard fullCheckIsSafe else {
            runScan(depth: .alertTriggered, reason: reason)
            return
        }
        runScan(depth: .full, reason: reason)
    }

    private func launch(depth: NetdiagRunner.Depth, reason: String,
                        target: String?, adoptAsReport: Bool) {
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return
        }
        isScanning = true
        scanStartedAt = Date()
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
                    self.hydratedReport = nil
                    self.alerts.evaluate(run: result.snapshot)
                }
                if let st = result.snapshot.speedtest, st.downMbps != nil {
                    self.latestSpeedTest = st
                    self.latestSpeedTestAt = result.finishedAt
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

    func stopLatencyTest() { monitor.endBurst() }

    func consumeRequestedDestination() -> MainDestination? {
        defer { requestedDestination = nil }
        return requestedDestination
    }

    /// An alert fired. Run a scan so the notification can be replaced with
    /// the CLI's own explanation — that in-place update is the entire point
    /// of the trigger.
    private func handleAlertFired(_ def: AlertDefinition) {
        // Recorded regardless of scanOnAlert: the timeline's job is to
        // show every alert that fired, not just the ones the auto-scan
        // preference happened to act on.
        eventLog.record(kind: "alert", summary: def.title,
                        ruleID: def.rules.first)
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

    // MARK: - Presentation helpers

    /// Refresh `liveSSID` from CoreWLAN. Called once per monitor sample
    /// rather than from a view body: a `CWWiFiClient` read is a real
    /// syscall, and `wifiDisplayName` is read on every redraw of an
    /// always-visible menu. Returns nil when Location is not authorized —
    /// CoreWLAN returns a redacted `<SSID>` / nil in that state, and
    /// passing that through would surface a raw placeholder as a name.
    private func refreshLiveWiFi() {
        // CoreWLAN's `interface()` returns the current Wi-Fi interface, but
        // has been observed returning nil on some builds even when
        // associated; fall back to the first power-on interface from
        // `interfaces()` before giving up.
        guard locationPermissions.isAuthorized else {
            if liveSSID != nil { log.debug("wifi: location not authorized — SSID unavailable") }
            liveSSID = nil
            return
        }
        let client = CWWiFiClient.shared()
        let iface = client.interface() ?? client.interfaces()?.first { $0.powerOn() }
        guard let iface else {
            log.debug("wifi: no CoreWLAN interface (on ethernet, or WiFi off)")
            liveSSID = nil
            return
        }
        let name = iface.ssid()
        if let name, !name.isEmpty {
            log.debug("wifi: live SSID read OK")
        } else {
            log.debug("wifi: CoreWLAN interface present but ssid() returned nil — location grant may be provisional or revoked")
        }
        liveSSID = (name?.isEmpty ?? true) ? nil : name
    }

    /// Adopt the live SSID as the current network's display name when no
    /// real name is recorded yet. The CLI records networks in
    /// baseline.jsonl with a MAC-keyed id and a redacted label (TCC
    /// attributes `ipconfig getsummary` to `/usr/sbin/ipconfig`, not this
    /// .app), so without this a network the user has granted Location for
    /// still shows up as "wifi:mac=…" in the Networks tab and in search
    /// forever. The GUI's CoreWLAN `ssid()` *does* see the real name, so
    /// the moment we have it we record it as the network's custom name —
    /// the same store `displayName` and the Networks-tab search already
    /// read. Joins on `historyJoinID` (the `--history` group key), not the
    /// raw sample id: the rename has to land on the same key the Networks
    /// tab renders by, or the name shows on Home and not there — the exact
    /// bug this replace fixed. Never overwrites a name that is not ugly
    /// (a user rename, or a real SSID the CLI captured under sudo), and
    /// writes at most once per network per name change rather than every
    /// sample.
    private func adoptLiveSSIDAsNameIfNeeded() {
        guard let live = liveSSID, !live.isEmpty,
              !live.contains("<redacted>"), !live.contains("hidden by macOS"),
              let id = monitor.latest?.network.historyJoinID else { return }
        let current = history.displayName(for: id)
        let currentIsUgly = current.isEmpty || current == id
            || current.contains("<redacted>") || current.contains("hidden by macOS")
            || Self.isRawNetworkKey(current)
        guard currentIsUgly, current != live else { return }
        history.rename(id, to: live)
        log.info("adopted live SSID as name for \(id, privacy: .public)")
    }

    /// True when a "name" is actually a raw network key rather than
    /// anything a person wrote or recognised — `wifi:mac=AA:BB:…` (the
    /// record format), `mac:aa:bb:…` / `gw:…` / `ssid:…` (the history
    /// group format). Both spellings must be caught here: renames can
    /// predate the group-id join, and the group key is what a network with
    /// no name at all falls back to in `displayName`.
    static func isRawNetworkKey(_ s: String) -> Bool {
        s.starts(with: "wifi:mac=") || s.starts(with: "lan:mac=")
            || s.starts(with: "wifi:ssid=") || s.starts(with: "lan:gw=")
            || s.starts(with: "mac:") || s.starts(with: "gw:")
            || s.starts(with: "ssid:")
    }

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
        if Defaults.monitoringEnabled && !monitor.isRunning { return .warning }
        if let sample = monitor.latest { return sample.health }
        if let run = latestRun { return run.snapshot.worstSeverity }
        return .warning
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
        if !monitor.isRunning && monitor.lastError == nil {
            return "Reconnecting to the connection monitor…"
        }
        if let sample = monitor.latest, !sample.link.up {
            return "Your Mac has no network connection at all."
        }
        if let sample = monitor.latest, sample.status.measurement != "measured" {
            return "Checking your connection — a live internet reading is not available yet."
        }
        if let sample = monitor.latest, sample.status.severity == "critical" || sample.status.severity == "warn" {
            for ruleID in sample.status.rules {
                if let rule = rulesCatalog.catalog?[ruleID] {
                    if let blurb = rule.blurb, !blurb.isEmpty {
                        return blurb
                    }
                    if let title = rule.title, !title.isEmpty {
                        return title
                    }
                }
            }
        }
        if let cause = latestRun?.snapshot.mostLikelyRootCause, !cause.isEmpty {
            return cause
        }
        if monitor.latest == nil && latestRun == nil { return "Starting up…" }
        return "Nothing obviously wrong — your network looks healthy."
    }

    /// A displayable network name, or `nil` when there isn't a clean one —
    /// never the raw `network.id`/`network.label` a redacted or
    /// not-yet-permitted record can carry (`"wifi:mac=…"`,
    /// `"<redacted>"`, `"hidden by macOS"`). Shared by `DropdownView`'s
    /// quiet-line caption and `HomeView`'s Wi-Fi row — one place, so the
    /// two can't describe the same network two different ways.
    ///
    /// Without Location Services, macOS never hands this app a real SSID,
    /// so the only name worth showing is one the user typed themselves in
    /// `HistoryStore.displayName` — a raw `network.id` in that state is a
    /// MAC-keyed string nobody recognizes, not a name.
    var wifiDisplayName: String? {
        // A user-assigned rename wins over everything — it is the name the
        // user themselves typed, so it is the name they expect to see.
        // Looked up by the history group key so a rename made anywhere
        // (the Networks tab, the adopt-as-name path) is found from here
        // too.
        if let id = monitor.latest?.network.historyJoinID {
            let custom = history.displayName(for: id)
            if !custom.isEmpty, custom != id, !custom.contains("<redacted>"),
               !custom.contains("hidden by macOS"), !Self.isRawNetworkKey(custom) {
                return custom
            }
        }
        // CoreWLAN's live SSID, available only with Location Services. The
        // CLI's own SSID reading is redacted by TCC even when the app is
        // granted (see `liveSSID`'s header), so this is the primary source
        // for the current network's real name — not a fallback.
        if let live = liveSSID, !live.isEmpty,
           !live.contains("<redacted>"), !live.contains("hidden by macOS") {
            return live
        }
        // Without Location and without a rename, the CLI's raw label is a
        // MAC-keyed string nobody recognises; hide it rather than show
        // furniture that reads as a bug.
        let raw = monitor.latest?.network.label ?? latestRun?.snapshot.network.label
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("<redacted>") || raw.contains("hidden by macOS")
            || Self.isRawNetworkKey(raw) {
            return nil
        }
        return raw
    }
}
