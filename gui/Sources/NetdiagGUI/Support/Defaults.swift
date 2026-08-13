import Foundation

/// Every persisted preference, in one place.
///
/// A key that any *view* reads must also be mirrored as a property on
/// `AppSettings` — views observe that wrapper, never this enum directly,
/// so an unmirrored key would render once and go stale.
///
/// Note what is *not* here: no thresholds. The cadence intervals below are
/// how often to look, which is a preference; what counts as lossy is a
/// judgement, and it lives in lib/thresholds.sh where the CLI can act on
/// it too. If a setting ever needs a number that decides whether something
/// is wrong, it belongs in the CLI and this file should read it back.
enum Defaults {

    /// `UserDefaults.standard`, with the registered fallbacks folded into
    /// this lazy initializer instead of a separate `registerDefaults()`
    /// call site.
    ///
    /// `AppSettings` snapshots these values into `@Observable` storage as
    /// part of `NetdiagCoordinator`'s property-default phase, which Swift
    /// runs *before* a custom `init()`'s body — i.e. before
    /// `NetdiagApp.init()` could reach a separate registration call.
    /// Registering here, on first touch of `d` itself, makes the order the
    /// app happens to construct things in unable to matter: every getter
    /// and setter below goes through `d`, so registration is guaranteed to
    /// have already run by the time any of them do.
    private static let d: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.monitoringEnabled: true,
            Key.fastInterval: 10,
            Key.degradedInterval: 5,
            Key.mediumInterval: 60,
            Key.slowInterval: 300,
            Key.menuBarStyle: MenuBarStyle.dotAndFlag.rawValue,
            Key.expertExpanded: false,
            Key.pauseOnDisplaySleep: true,
            Key.pauseOnBattery: false,
            Key.scanOnNewNetwork: true,
            Key.scanOnAlert: true,
            Key.hasOnboarded: false,
        ])
        return defaults
    }()

    private enum Key {
        static let monitoringEnabled  = "monitoringEnabled"
        static let fastInterval       = "monitorFastInterval"
        static let degradedInterval   = "monitorDegradedInterval"
        static let mediumInterval     = "monitorMediumInterval"
        static let slowInterval       = "monitorSlowInterval"
        static let menuBarStyle       = "menuBarStyle"
        static let expertExpanded     = "expertExpanded"
        static let binaryPath         = "netdiagBinaryPath"
        static let networkNames       = "networkNames"
        static let networkMerges      = "networkMerges"
        static let seenNetworks       = "seenNetworks"
        static let hasOnboarded       = "hasOnboarded"
        static let pauseOnDisplaySleep = "pauseOnDisplaySleep"
        static let pauseOnBattery     = "pauseOnBattery"
        static let scanOnNewNetwork   = "scanOnNewNetwork"
        static let scanOnAlert        = "scanOnAlert"
        static let disabledAlerts     = "disabledAlerts"
    }

    // MARK: - Monitoring

    static var monitoringEnabled: Bool {
        get { d.bool(forKey: Key.monitoringEnabled) }
        set { d.set(newValue, forKey: Key.monitoringEnabled) }
    }

    /// Clamped on read, not just on write. A value edited straight into the
    /// plist — or left over from an older build — would otherwise reach the
    /// CLI's own validation and abort the monitor at startup, which the
    /// user sees as "monitoring just stops working".
    static var fastInterval: Int {
        get { clamp(d.integer(forKey: Key.fastInterval), 2, 300, fallback: 10) }
        set { d.set(newValue, forKey: Key.fastInterval) }
    }
    static var degradedInterval: Int {
        get { clamp(d.integer(forKey: Key.degradedInterval), 2, 300, fallback: 5) }
        set { d.set(newValue, forKey: Key.degradedInterval) }
    }
    static var mediumInterval: Int {
        get { clamp(d.integer(forKey: Key.mediumInterval), 10, 3600, fallback: 60) }
        set { d.set(newValue, forKey: Key.mediumInterval) }
    }
    static var slowInterval: Int {
        get { clamp(d.integer(forKey: Key.slowInterval), 60, 7200, fallback: 300) }
        set { d.set(newValue, forKey: Key.slowInterval) }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int, fallback: Int) -> Int {
        v == 0 ? fallback : min(max(v, lo), hi)
    }

    /// The on-demand latency test: how fast to sample, and for how long.
    ///
    /// Not persisted and not a preference — a bounded window the user opts
    /// into per press. Two seconds is the CLI's own floor for
    /// `--monitor-fast-interval`, not a number chosen here; going below it
    /// would have the monitor reject its arguments and exit at startup.
    /// Neither value decides whether anything is good or bad.
    static let latencyTestInterval = 2
    static let latencyTestDuration: TimeInterval = 60

    static var pauseOnDisplaySleep: Bool {
        get { d.bool(forKey: Key.pauseOnDisplaySleep) }
        set { d.set(newValue, forKey: Key.pauseOnDisplaySleep) }
    }
    static var pauseOnBattery: Bool {
        get { d.bool(forKey: Key.pauseOnBattery) }
        set { d.set(newValue, forKey: Key.pauseOnBattery) }
    }

    // MARK: - Auto-run triggers

    static var scanOnNewNetwork: Bool {
        get { d.bool(forKey: Key.scanOnNewNetwork) }
        set { d.set(newValue, forKey: Key.scanOnNewNetwork) }
    }
    static var scanOnAlert: Bool {
        get { d.bool(forKey: Key.scanOnAlert) }
        set { d.set(newValue, forKey: Key.scanOnAlert) }
    }

    // MARK: - Presentation

    static var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: d.string(forKey: Key.menuBarStyle) ?? "") ?? .dotAndFlag }
        set { d.set(newValue.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Whether the expert disclosure is open. Persisted so it is a
    /// disclosure the user opens once and keeps, never a mode chosen at
    /// first launch — an expert should not have to re-open it every time,
    /// and a non-technical user should never be asked which they are.
    static var expertExpanded: Bool {
        get { d.bool(forKey: Key.expertExpanded) }
        set { d.set(newValue, forKey: Key.expertExpanded) }
    }

    static var hasOnboarded: Bool {
        get { d.bool(forKey: Key.hasOnboarded) }
        set { d.set(newValue, forKey: Key.hasOnboarded) }
    }

    static var binaryPath: String {
        get { d.string(forKey: Key.binaryPath) ?? "" }
        set { d.set(newValue, forKey: Key.binaryPath) }
    }

    // MARK: - Networks

    static var networkNames: [String: String] {
        get { d.dictionary(forKey: Key.networkNames) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.networkNames) }
    }

    static var networkMerges: [String: String] {
        get { d.dictionary(forKey: Key.networkMerges) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.networkMerges) }
    }

    /// Networks this app has seen live. Distinct from the history: a
    /// never-seen network should trigger exactly one scan, and the history
    /// only learns about the network *because* of that scan — so keying the
    /// trigger off history alone would fire it twice.
    static var seenNetworks: Set<String> {
        get { Set(d.stringArray(forKey: Key.seenNetworks) ?? []) }
        set { d.set(Array(newValue), forKey: Key.seenNetworks) }
    }

    // MARK: - Alerts
    //
    // All twelve ship on. The three that are nag-prone are tamed with long
    // dwell and long cooldown in AlertDefinitions rather than being shipped
    // off, because an alert the user never sees is indistinguishable from
    // one that does not exist.

    static var disabledAlerts: Set<String> {
        get { Set(d.stringArray(forKey: Key.disabledAlerts) ?? []) }
        set { d.set(Array(newValue), forKey: Key.disabledAlerts) }
    }

    static func isAlertEnabled(_ id: String) -> Bool { !disabledAlerts.contains(id) }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case dotOnly = "dot"
    case dotAndFlag = "dot+flag"
    case dotFlagAndIP = "dot+flag+ip"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dotOnly:      return "Status dot only"
        case .dotAndFlag:   return "Status dot and country flag"
        case .dotFlagAndIP: return "Status dot, flag, and IP address"
        }
    }
}
