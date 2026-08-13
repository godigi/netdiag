import Foundation

/// The observable face of `Defaults`.
///
/// `UserDefaults` has no way to tell a `View` that a value changed out
/// from under it, so a view reading `Defaults.foo` straight from its body
/// stayed stale until something else happened to redraw it — this app
/// used to paper over that for exactly one view (`MenuBarLabel`) with a
/// hand-posted `.netdiagSettingsChanged` notification. `AppSettings` wraps
/// every preference a view actually reads in an `@Observable` class
/// instead, so SwiftUI's own dependency tracking does that invalidation
/// for every view at once, and the notification hack goes away entirely.
///
/// `Defaults` stays the storage layer: it owns the `UserDefaults` keys and
/// the clamping logic on read (see its own header), and every setter here
/// writes straight through to it rather than duplicating either. Reading
/// `Defaults` directly from a *view body* is what this class exists to
/// replace; reading it from `NetdiagCoordinator` or another service that
/// isn't rendering anything is unaffected — those already recompute
/// whenever the coordinator's own observable state changes.
@MainActor
@Observable
final class AppSettings {

    var monitoringEnabled: Bool {
        didSet { Defaults.monitoringEnabled = monitoringEnabled }
    }
    var fastInterval: Int {
        didSet { Defaults.fastInterval = fastInterval }
    }
    var mediumInterval: Int {
        didSet { Defaults.mediumInterval = mediumInterval }
    }
    var slowInterval: Int {
        didSet { Defaults.slowInterval = slowInterval }
    }
    var pauseOnDisplaySleep: Bool {
        didSet { Defaults.pauseOnDisplaySleep = pauseOnDisplaySleep }
    }
    var pauseOnBattery: Bool {
        didSet { Defaults.pauseOnBattery = pauseOnBattery }
    }
    var scanOnNewNetwork: Bool {
        didSet { Defaults.scanOnNewNetwork = scanOnNewNetwork }
    }
    var scanOnAlert: Bool {
        didSet { Defaults.scanOnAlert = scanOnAlert }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { Defaults.menuBarStyle = menuBarStyle }
    }
    /// Persisted so the disclosure a user opens once stays open — see
    /// `Defaults.expertExpanded`. Observable now too, so opening it on the
    /// live report and opening a stored run show the same state instead of
    /// each view remembering its own copy from whenever it last appeared.
    var expertExpanded: Bool {
        didSet { Defaults.expertExpanded = expertExpanded }
    }
    var binaryPath: String {
        didSet { Defaults.binaryPath = binaryPath }
    }
    var disabledAlerts: Set<String> {
        didSet { Defaults.disabledAlerts = disabledAlerts }
    }
    var hasOnboarded: Bool {
        didSet { Defaults.hasOnboarded = hasOnboarded }
    }

    /// Pass-through, not a preference: the on-demand latency test's own
    /// sampling window. See `Defaults.latencyTestInterval` for why it
    /// isn't persisted. Exposed here too so a view never has to reach past
    /// `AppSettings` back into `Defaults` for anything.
    let latencyTestInterval = Defaults.latencyTestInterval
    let latencyTestDuration = Defaults.latencyTestDuration

    // Every property above must be hydrated here and must NOT carry an
    // inline default. The compiler's definite-initialization check is the
    // only thing that catches "added a preference, forgot to hydrate it" —
    // and an inline default (`var foo = false { didSet … }`) disarms it:
    // the property compiles, persists on write, and silently reverts the
    // user's choice at every launch.
    init() {
        monitoringEnabled = Defaults.monitoringEnabled
        fastInterval = Defaults.fastInterval
        mediumInterval = Defaults.mediumInterval
        slowInterval = Defaults.slowInterval
        pauseOnDisplaySleep = Defaults.pauseOnDisplaySleep
        pauseOnBattery = Defaults.pauseOnBattery
        scanOnNewNetwork = Defaults.scanOnNewNetwork
        scanOnAlert = Defaults.scanOnAlert
        menuBarStyle = Defaults.menuBarStyle
        expertExpanded = Defaults.expertExpanded
        binaryPath = Defaults.binaryPath
        disabledAlerts = Defaults.disabledAlerts
        hasOnboarded = Defaults.hasOnboarded
    }
}
