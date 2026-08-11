import SwiftUI

struct SettingsView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator

    @State private var monitoring = Defaults.monitoringEnabled
    @State private var fast = Double(Defaults.fastInterval)
    @State private var medium = Double(Defaults.mediumInterval)
    @State private var slow = Double(Defaults.slowInterval)
    @State private var pauseSleep = Defaults.pauseOnDisplaySleep
    @State private var pauseBattery = Defaults.pauseOnBattery
    @State private var scanNew = Defaults.scanOnNewNetwork
    @State private var scanAlert = Defaults.scanOnAlert
    @State private var style = Defaults.menuBarStyle
    @State private var binaryPath = Defaults.binaryPath
    @State private var disabledAlerts = Defaults.disabledAlerts

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            alerts.tabItem { Label("Alerts", systemImage: "bell") }
            advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Monitoring") {
                Toggle("Watch my connection continuously", isOn: $monitoring)
                    .onChange(of: monitoring) { _, new in
                        coordinator.setMonitoring(enabled: new)
                        settingsChanged()
                    }

                // Sliders drive the CLI's own --monitor-*-interval flags.
                // These are "how often to look", which is a preference.
                // What counts as a problem is not here and never will be —
                // it lives in lib/thresholds.sh so the CLI and the app can
                // never disagree about it.
                LabeledContent("Check the router every") {
                    HStack {
                        Slider(value: $fast, in: 2...60, step: 1)
                        Text("\(Int(fast))s").monospacedDigit().frame(width: 38)
                    }
                }
                LabeledContent("Check DNS and Wi-Fi every") {
                    HStack {
                        Slider(value: $medium, in: 15...600, step: 5)
                        Text("\(Int(medium))s").monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Check your public IP every") {
                    HStack {
                        Slider(value: $slow, in: 60...1800, step: 30)
                        Text("\(Int(slow))s").monospacedDigit().frame(width: 48)
                    }
                }
                Text("Faster checks notice problems sooner and use a little more battery. Your public IP is looked up from an outside service, so that one stays slow on purpose.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Battery") {
                Toggle("Pause while the display is asleep", isOn: $pauseSleep)
                    .onChange(of: pauseSleep) { _, new in
                        Defaults.pauseOnDisplaySleep = new; settingsChanged()
                    }
                Toggle("Pause on low battery", isOn: $pauseBattery)
                    .onChange(of: pauseBattery) { _, new in
                        Defaults.pauseOnBattery = new; settingsChanged()
                    }
            }

            Section("Menu bar") {
                Picker("Show", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: style) { _, new in
                    Defaults.menuBarStyle = new; settingsChanged()
                }
            }
        }
        .formStyle(.grouped)
        // Restart on commit rather than on every slider tick: each change
        // respawns the monitor process, and dragging a slider would
        // otherwise spawn one per pixel.
        .onChange(of: fast) { _, new in Defaults.fastInterval = Int(new) }
        .onChange(of: medium) { _, new in Defaults.mediumInterval = Int(new) }
        .onChange(of: slow) { _, new in Defaults.slowInterval = Int(new) }
        .onDisappear { coordinator.applyCadenceSettings() }
    }

    // MARK: - Alerts

    private var alerts: some View {
        Form {
            Section {
                if !coordinator.alerts.notificationsAuthorized {
                    HStack {
                        Label("Notifications are off — alerts can't reach you.",
                              systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Turn on") {
                            Task { await coordinator.alerts.requestAuthorization() }
                        }
                    }
                }
                Toggle("Run a check automatically when something breaks", isOn: $scanAlert)
                    .onChange(of: scanAlert) { _, new in Defaults.scanOnAlert = new }
                Toggle("Run a check the first time I join a network", isOn: $scanNew)
                    .onChange(of: scanNew) { _, new in Defaults.scanOnNewNetwork = new }
                Text("An automatic check skips the speed test, so it won't slow down a connection that is already struggling.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Tell me about") {
                ForEach(AlertDefinition.all) { def in
                    Toggle(def.title, isOn: Binding(
                        get: { !disabledAlerts.contains(def.id) },
                        set: { on in
                            Defaults.setAlert(def.id, enabled: on)
                            disabledAlerts = Defaults.disabledAlerts
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
        .task { await coordinator.alerts.refreshAuthorization() }
    }

    // MARK: - Advanced

    private var advanced: some View {
        Form {
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
                    TextField("Leave blank to find it automatically", text: $binaryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseBinary() }
                }
                .onChange(of: binaryPath) { _, new in Defaults.binaryPath = new }
                Text(resolvedPathLabel)
                    .font(.caption)
                    .foregroundStyle(BinaryLocator.resolve() == nil ? .red : .secondary)
                    .textSelection(.enabled)
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
        .task { await coordinator.watcher.refresh() }
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
            binaryPath = url.path
            Defaults.binaryPath = url.path
        }
    }

    private func settingsChanged() {
        NotificationCenter.default.post(name: .netdiagSettingsChanged, object: nil)
    }
}
