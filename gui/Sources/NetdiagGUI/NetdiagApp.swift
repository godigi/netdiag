import SwiftUI
import AppKit

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

    var body: some Scene {
        // .window style rather than .menu: the dropdown is a small custom
        // panel with a status line, a Run button and live values, none of
        // which a menu can lay out.
        MenuBarExtra {
            DropdownView()
                .environment(coordinator)
                .environment(coordinator.appSettings)
                .frame(width: 340)
        } label: {
            MenuBarLabel(coordinator: coordinator, appSettings: coordinator.appSettings)
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
                .environment(coordinator.appSettings)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 640)

        Window("netdiag Settings", id: WindowID.settings) {
            SettingsView()
                .environment(coordinator)
                .environment(coordinator.appSettings)
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        Window("Welcome to netdiag", id: WindowID.onboarding) {
            OnboardingView()
                .environment(coordinator)
                .environment(coordinator.appSettings)
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
    var appSettings: AppSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.dot(for: coordinator.currentHealth))
            if appSettings.menuBarStyle != .dotOnly,
               let flag = Flag.emoji(forISOCode: countryISO) {
                Text(flag)
            }
            if appSettings.menuBarStyle == .dotFlagAndIP, let ip = publicIP {
                Text(ip).font(Theme.Font.compactMonospace)
            }
        }
    }

    /// The health dot, as a *non-template* NSImage.
    ///
    /// This is not the obvious way to write it, and the obvious way is
    /// broken. `Image(systemName:).foregroundStyle(.green)` inside a
    /// MenuBarExtra label renders grey: SwiftUI hands the label to an
    /// NSStatusItem, which treats an SF Symbol as a template image and
    /// throws the colour away so the icon can invert with the menu bar. A
    /// status dot whose entire job is to be green, amber or red cannot be a
    /// template, so the symbol is rasterised here with an explicit palette
    /// colour and `isTemplate = false`.
    ///
    /// Colour is never the only signal — the three symbols differ in shape
    /// as well, which is what makes the state readable to someone who can't
    /// distinguish red from green.
    @MainActor
    private static func dot(for health: Health) -> NSImage {
        if let cached = dotCache[health.symbol] { return cached }
        let colour = health.nsColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        let image = NSImage(systemSymbolName: health.symbol,
                            accessibilityDescription: health.accessibilityLabel)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        dotCache[health.symbol] = image
        return image
    }

    /// Rebuilt only when health changes, not on every menu-bar redraw.
    @MainActor
    private static var dotCache: [String: NSImage] = [:]

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
