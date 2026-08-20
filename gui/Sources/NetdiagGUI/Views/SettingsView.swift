import SwiftUI

struct SettingsView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    /// The About section's own answer from the capabilities handshake.
    /// `nil` until the first probe returns — held here, not read from
    /// `CapabilityStore` inline, because that store is an actor and a
    /// view body can't `await` it.
    @State private var capabilities: CapabilityState?
    @State private var isRechecking = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            alerts.tabItem { Label("Alerts", systemImage: "bell") }
            advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 560)
        .onAppear { coordinator.windowAppeared() }
        .onDisappear { coordinator.windowDisappeared() }
    }

    // MARK: - General

    private var general: some View {
        @Bindable var appSettings = appSettings
        return Form {
            Section("Monitoring") {
                Toggle("Watch my connection continuously", isOn: $appSettings.monitoringEnabled)
                    .onChange(of: appSettings.monitoringEnabled) { _, new in
                        coordinator.setMonitoring(enabled: new)
                    }

                // Sliders drive the CLI's own --monitor-*-interval flags.
                // These are "how often to look", which is a preference.
                // What counts as a problem is not here and never will be —
                // it lives in lib/thresholds.sh so the CLI and the app can
                // never disagree about it.
                LabeledContent("Check the router every") {
                    HStack {
                        Slider(value: intervalBinding(\.fastInterval), in: 2...60, step: 1)
                        Text("\(appSettings.fastInterval)s").monospacedDigit().frame(width: 38)
                    }
                }
                LabeledContent("Check DNS and Wi-Fi every") {
                    HStack {
                        Slider(value: intervalBinding(\.mediumInterval), in: 15...600, step: 5)
                        Text("\(appSettings.mediumInterval)s").monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Check your public IP every") {
                    HStack {
                        Slider(value: intervalBinding(\.slowInterval), in: 60...1800, step: 30)
                        Text("\(appSettings.slowInterval)s").monospacedDigit().frame(width: 48)
                    }
                }
                Text("Faster checks notice problems sooner and use a little more battery. Your public IP is looked up from an outside service, so that one stays slow on purpose.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Battery") {
                Toggle("Pause while the display is asleep", isOn: $appSettings.pauseOnDisplaySleep)
                Toggle("Pause on low battery", isOn: $appSettings.pauseOnBattery)
            }

            Section("Menu bar") {
                Picker("Show", selection: $appSettings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates daily", isOn: $appSettings.autoCheckUpdates)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coordinator.updateChecker.statusMessage)
                            .font(.callout)
                            .fontWeight(coordinator.updateChecker.hasUpdate ? .semibold : .regular)
                            .foregroundStyle(coordinator.updateChecker.hasUpdate ? .orange : .primary)

                        if let last = coordinator.updateChecker.lastCheckedDate {
                            Text("Last checked: \(RelativeTime.string(from: last))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if coordinator.updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                    } else if coordinator.updateChecker.isDownloading {
                        ProgressView(value: coordinator.updateChecker.downloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                    } else if coordinator.updateChecker.hasUpdate {
                        Button("Install Update") {
                            coordinator.updateChecker.downloadAndInstallUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Check Now") {
                            coordinator.updateChecker.checkForUpdates(manual: true)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)

                if let err = coordinator.updateChecker.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // The monitor restarts once, when the window closes, rather than
        // once per slider tick: each restart respawns the process, and
        // the intervals are command-line arguments it has no way to be
        // told about mid-run.
        .onDisappear { coordinator.applyCadenceSettings() }
    }

    /// A `Binding<Double>` for a `Slider`, over one of `AppSettings`'s
    /// `Int` cadence properties. Note `Defaults`' clamping is read-side
    /// only — these sliders stay in range because their bounds sit inside
    /// the clamp bounds, not because the write path clamps.
    private func intervalBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(appSettings[keyPath: keyPath]) },
            set: { appSettings[keyPath: keyPath] = Int($0) }
        )
    }

    // MARK: - Alerts

    private var alerts: some View {
        @Bindable var appSettings = appSettings
        return Form {
            Section("Permissions") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                        Text(coordinator.alerts.notificationsAuthorized
                             ? "Allowed — alerts appear when connectivity drops."
                             : "Off — netdiag cannot alert you when something breaks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !coordinator.alerts.notificationsAuthorized {
                        Button("Turn on") {
                            Task { await coordinator.alerts.requestAuthorization() }
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi & Location Access")
                        Text(coordinator.locationPermissions.isAuthorized
                             ? "Allowed — Wi-Fi names and detailed radio diagnostics unlocked."
                             : (coordinator.locationPermissions.isDeniedOrRestricted
                                ? "Restricted — macOS hides Wi-Fi network names."
                                : "Not enabled — required for Wi-Fi names and radio diagnostics."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !coordinator.locationPermissions.isAuthorized {
                        Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Open Settings" : "Allow") {
                            if coordinator.locationPermissions.isDeniedOrRestricted {
                                coordinator.locationPermissions.openSystemSettings()
                            } else {
                                coordinator.locationPermissions.requestOrOpenSettings()
                            }
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Automation") {
                Toggle("Run a check automatically when something breaks", isOn: $appSettings.scanOnAlert)
                Toggle("Run a check the first time I join a network", isOn: $appSettings.scanOnNewNetwork)
                Text("An automatic check skips the speed test, so it won't slow down a connection that is already struggling.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Tell me about") {
                ForEach(AlertDefinition.all) { def in
                    Toggle(def.title, isOn: Binding(
                        get: { !appSettings.disabledAlerts.contains(def.id) },
                        set: { on in
                            var set = appSettings.disabledAlerts
                            if on { set.remove(def.id) } else { set.insert(def.id) }
                            appSettings.disabledAlerts = set
                        }))
                }
            }

            Section {
                Text("netdiag waits before telling you about something, and won't repeat itself for a while afterwards — so a connection that wobbles for a few seconds stays quiet. Weak-signal warnings wait two minutes and repeat at most once an hour.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            await coordinator.alerts.refreshAuthorization()
            coordinator.locationPermissions.refresh()
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        @Bindable var appSettings = appSettings
        return Form {
            Section("Background checks") {
                HStack {
                    Text(coordinator.watcher.isInstalled
                         ? "Running a check every 15 minutes."
                         : "Off — history only grows when a check runs.")
                    Spacer()
                    if coordinator.watcher.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(coordinator.watcher.isInstalled ? "Turn off" : "Turn on") {
                            Task {
                                if coordinator.watcher.isInstalled {
                                    await coordinator.watcher.uninstall()
                                } else {
                                    await coordinator.watcher.install()
                                }
                            }
                        }
                    }
                }
                Text("Installs a small background job (launchd) that records a quick check every 15 minutes. This is what makes the History charts worth looking at.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = coordinator.watcher.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("netdiag command") {
                HStack {
                    TextField("Leave blank to find it automatically", text: $appSettings.binaryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseBinary() }
                }
                Text(resolvedPathLabel)
                    .font(.caption)
                    .foregroundStyle(BinaryLocator.resolve() == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }

            about

            Section {
                Button("Show welcome tour again") {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
                Text("Reopens the three-step setup — notifications, Wi-Fi names, background checks — shown on first launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Where things are kept") {
                LabeledContent("Reports and history") {
                    Text("~/net-diag").font(.system(.caption, design: .monospaced))
                }
                Button("Open folder in Finder") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("net-diag"))
                }
                .buttonStyle(.link)
            }

            Section {
                Text("netdiag.app doesn't diagnose anything itself — every measurement, every threshold and every explanation comes from the netdiag command-line tool. The app shows you what it found.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            await coordinator.watcher.refresh()
            capabilities = await CapabilityStore.shared.current()
        }
    }

    private var resolvedPathLabel: String {
        BinaryLocator.resolve().map { "Using: \($0)" } ?? BinaryLocator.missingBinaryMessage
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            appSettings.binaryPath = url.path
        }
    }

    // MARK: - About
    //
    // Facts, not verdicts — every value below is a version string or a
    // boolean off the capabilities handshake, never a judgement about the
    // network (that stays lib/thresholds.sh's job, per CLAUDE.md).

    private var about: some View {
        Section("About") {
            LabeledContent("netdiag.app") { Text(AppVersion.display) }
            LabeledContent("CLI in use") {
                Text(BinaryLocator.resolve() ?? "not found")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            aboutHandshake
            HStack {
                Spacer()
                if isRechecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Re-check") {
                        Task {
                            isRechecking = true
                            capabilities = await CapabilityStore.shared.recheck()
                            // The deliberate recovery point. The monitor's
                            // capability-gate failure doesn't retry on its
                            // own (a doomed CLI would just spin the backoff
                            // loop), so a user following the error's advice
                            // — fixing the override — completes it here:
                            // a re-check that comes back modern restarts
                            // the monitor they still have switched on.
                            if case .modern = capabilities,
                               appSettings.monitoringEnabled,
                               !coordinator.monitor.isRunning {
                                coordinator.monitor.start()
                            }
                            // Same recovery point for the rules catalog: a
                            // user landed here because *something* about
                            // the resolved CLI just changed, and that's
                            // exactly when a catalog cached for the old
                            // version needs re-checking against the new
                            // one rather than waiting for some other view
                            // to happen to call `ensureLoaded()` again.
                            await coordinator.rulesCatalog.refresh()
                            isRechecking = false
                        }
                    }
                }
            }
        }
    }

    /// The part of the About section that depends on the handshake having
    /// actually returned — the CLI's own version, its dependencies, and
    /// (for a CLI old enough to predate the handshake) an explanation of
    /// why none of that is available.
    @ViewBuilder
    private var aboutHandshake: some View {
        switch capabilities {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking netdiag's version…").font(.caption).foregroundStyle(.secondary)
            }
        case .unavailable:
            Text("Couldn't reach the netdiag command to check its version.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .legacy:
            Text("This netdiag command predates the version check this app uses, so its version and dependencies aren't available. It still runs — Monitor, History and Show need an update to work from this app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .modern(let caps):
            LabeledContent("netdiag CLI") {
                Text(caps.version.map { "v\($0)" } ?? "unknown version")
            }
            LabeledContent("Speed test tool") { Text(speedtestLabel(caps.deps.speedtest)) }
            LabeledContent("bash") { Text(caps.deps.bash ?? "unknown") }
            LabeledContent("python3") { Text(caps.deps.python3 ?? "not installed") }
            LabeledContent("jq") { Text(boolLabel(caps.deps.jq)) }
            LabeledContent("mtr") { Text(boolLabel(caps.deps.mtr)) }
            LabeledContent("gping") { Text(boolLabel(caps.deps.gping)) }
            if let schemas = caps.schemas, !schemas.isEmpty {
                Text("Schemas: " + schemas.sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func speedtestLabel(_ value: String?) -> String {
        switch value {
        case "ookla": return "Ookla speedtest"
        case "cli":   return "speedtest-cli"
        default:      return "not installed — speed tests will be skipped"
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        switch value {
        case true?:  return "installed"
        case false?: return "not installed"
        case nil:    return "unknown"
        }
    }
}
