import SwiftUI

/// netdiag.app — a menu-bar client for the netdiag CLI.
///
/// The app is a *client*, not a second brain. It renders what the CLI
/// measures and decides; it holds no thresholds and composes no diagnosis
/// prose. The concrete rule: if a change here would add a number that
/// decides whether something is wrong, or a sentence explaining a network
/// fault, it belongs in `lib/` instead.
@main
struct NetdiagApp: App {

    @State private var coordinator = NetdiagCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    init() {
        Defaults.registerDefaults()
    }

    var body: some Scene {
        // .window style rather than .menu: the dropdown is a small custom
        // panel with a status line, a Run button and live values, none of
        // which a menu can lay out.
        MenuBarExtra {
            DropdownView()
                .environment(coordinator)
                .frame(width: 340)
        } label: {
            MenuBarLabel(coordinator: coordinator)
                // The only view guaranteed to exist at launch. An
                // LSUIElement app has no window on screen, so a .task on
                // the dropdown or the dashboard would not run until the
                // user opened one — and a monitor that only starts when
                // you click the icon is not a monitor.
                .task { await bootstrap() }
        }
        .menuBarExtraStyle(.window)

        Window("netdiag", id: WindowID.dashboard) {
            DashboardWindow()
                .environment(coordinator)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 640)

        Window("netdiag Settings", id: WindowID.settings) {
            SettingsView()
                .environment(coordinator)
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        Window("Welcome to netdiag", id: WindowID.onboarding) {
            OnboardingView()
                .environment(coordinator)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)
    }
}

extension NetdiagApp {
    /// Runs once, at launch.
    @MainActor
    private func bootstrap() async {
        guard !delegate.didBootstrap else { return }
        delegate.didBootstrap = true
        coordinator.start()

        if Defaults.hasOnboarded {
            // Grants can be revoked in System Settings between launches, so
            // the stored answer is a fact about last time, not about now.
            await coordinator.alerts.refreshAuthorization()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.onboarding)
        }
    }
}

/// Exists for two things SwiftUI's App protocol cannot express on its own:
/// a launch hook that fires without a window on screen, and a termination
/// hook that reaps the monitor child.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `.task` on a menu-bar label can re-run when the label's identity
    /// changes. Bootstrapping twice would spawn a second monitor process
    /// and leave the first orphaned.
    @MainActor var didBootstrap = false

    func applicationWillTerminate(_ notification: Notification) {
        // The monitor is a child process, and a child of a process that
        // dies without terminating it is re-parented to launchd and keeps
        // pinging the gateway forever. `netdiag --monitor` handles SIGTERM
        // cleanly; it just has to be sent.
        NotificationCenter.default.post(name: .netdiagWillTerminate, object: nil)
    }
}

extension Notification.Name {
    static let netdiagWillTerminate = Notification.Name("netdiagWillTerminate")
}

enum WindowID {
    static let dashboard = "dashboard"
    static let settings = "settings"
    static let onboarding = "onboarding"
}

/// Layer one of four: the menu-bar item itself.
///
/// Health dot, optionally a country flag, optionally the public IP —
/// configurable because the right amount of permanent screen furniture is
/// a matter of taste, and an always-visible IP address is a real privacy
/// consideration when screen-sharing.
struct MenuBarLabel: View {
    @Bindable var coordinator: NetdiagCoordinator
    @State private var style = Defaults.menuBarStyle

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: coordinator.currentHealth.symbol)
                .foregroundStyle(tint)
            if style != .dotOnly,
               let flag = Flag.emoji(forISOCode: countryISO) {
                Text(flag)
            }
            if style == .dotFlagAndIP, let ip = publicIP {
                Text(ip).font(.system(size: 11, design: .monospaced))
            }
        }
        .task {
            // UserDefaults is not observable, so re-read on appear and
            // whenever the settings window announces a change.
            style = Defaults.menuBarStyle
        }
        .onReceive(NotificationCenter.default.publisher(for: .netdiagSettingsChanged)) { _ in
            style = Defaults.menuBarStyle
        }
    }

    private var tint: Color {
        switch coordinator.currentHealth {
        case .healthy:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
    }

    private var publicIP: String? {
        let ip = coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
        guard let ip, !ip.isEmpty else { return nil }
        // IPv6 addresses are far too long for a menu bar. Show the last
        // group, which is the part that actually changes.
        if ip.contains(":") { return "…\(ip.split(separator: ":").last ?? "")" }
        return ip
    }
}

extension Notification.Name {
    /// Posted when a preference changes, so the views reading UserDefaults
    /// directly can refresh. UserDefaults is not @Observable and wrapping
    /// every key in @AppStorage would scatter the definitions this app
    /// deliberately keeps in one file.
    static let netdiagSettingsChanged = Notification.Name("netdiagSettingsChanged")
}
