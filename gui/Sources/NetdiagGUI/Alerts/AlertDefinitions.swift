import Foundation

/// The twelve alerts, and the timing that keeps them from becoming noise.
///
/// ── The line this file walks ───────────────────────────────────────────
/// Notification fatigue is the single most likely cause of this app being
/// switched off, and the defence is dwell and cooldown rather than fewer
/// alerts. So all twelve ship on; the three that would otherwise nag —
/// weak signal, lease expiring, slower than usual — carry deliberately long
/// dwells and cooldowns instead of being dropped. An alert nobody ever sees
/// is indistinguishable from one that does not exist.
///
/// ── What Swift is allowed to say ───────────────────────────────────────
/// `title` is a category label: two or three words naming which of twelve
/// things happened. That is navigation, not diagnosis.
///
/// Every *explanatory* sentence comes from the CLI. Before a scan lands,
/// the notification body is a neutral holding line; once it lands, the body
/// is replaced verbatim with `diagnosis[].summary` — prose the CLI already
/// writes for a non-technical reader ("You're losing packets between your
/// Mac and your router even though the WiFi signal is strong — the router
/// itself is misbehaving. Try rebooting it…"). Nothing in this target
/// composes a sentence about what is wrong with a network or what to do
/// about it. If a future edit adds one, it belongs in lib/diagnosis.sh.
struct AlertDefinition: Identifiable, Sendable {
    let id: String
    /// Category label shown as the notification title.
    let title: String
    /// Rule IDs from docs/DIAGNOSIS-RULES.md that raise this alert.
    let rules: Set<String>
    /// How long the condition must hold continuously before notifying.
    /// Zero means fire on the first observation — correct only for
    /// discrete events, never for a measurement.
    let dwell: TimeInterval
    /// Minimum gap between repeat notifications of the same alert.
    let cooldown: TimeInterval
    /// Whether to notify again when the condition clears.
    let resolves: Bool
    /// True when only a full scan can observe this — the monitor never
    /// claims it, so it is evaluated against a run's diagnosis array.
    let scanOnly: Bool
    /// Whether TCP-1 holding suppresses this alert. Every loss-derived
    /// alert says yes: on hotel and corporate WiFi, ICMP is blocked
    /// wholesale and a loss alert there is always a false one.
    let suppressedByICMPFilter: Bool
    /// Fire at most once per network rather than on a clock. For the two
    /// alerts that describe a property of *this* network rather than a
    /// condition that comes and goes.
    let oncePerNetwork: Bool

    /// Neutral holding text, shown only in the gap between the alert firing
    /// and the triggered scan landing. Deliberately says nothing about
    /// cause or remedy — that is the CLI's to say, and guessing here is how
    /// an app ends up contradicting its own report.
    let interimBody: String

    static let all: [AlertDefinition] = [
        AlertDefinition(
            id: "connection-lost", title: "No internet connection",
            rules: ["N1", "N1b", "P1", "P2"],
            dwell: 15, cooldown: 300, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: "Checking what happened…"),

        AlertDefinition(
            id: "wifi-unstable", title: "Connection is unstable",
            rules: ["G1", "G2", "G3", "WD-1"],
            // 60 s, not 15: a single bad minute on WiFi is ordinary. The
            // monitor's 10-packet probe already puts one dropped packet in
            // the warn band rather than the critical one, and the dwell
            // absorbs the rest.
            dwell: 60, cooldown: 1800, resolves: true, scanOnly: false,
            suppressedByICMPFilter: true, oncePerNetwork: false,
            interimBody: "Checking whether it's your Wi-Fi or your router…"),

        AlertDefinition(
            id: "dns-failing", title: "Websites aren't loading",
            rules: ["P1", "D1"],
            dwell: 60, cooldown: 1800, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: "Checking your name lookups…"),

        AlertDefinition(
            id: "public-ip-changed", title: "Your public IP address changed",
            rules: [],   // raised from a monitor event, not a rule
            dwell: 0, cooldown: 60, resolves: false, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: ""),

        AlertDefinition(
            id: "captive-portal", title: "This network needs you to sign in",
            rules: [],   // raised from public.captive_portal
            // 15 s after joining, because macOS shows its own sign-in sheet
            // first. This fires only when that sheet failed to appear —
            // which is exactly the moment a non-technical user is stranded
            // with a Wi-Fi icon that looks connected and no working web.
            dwell: 15, cooldown: 0, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: true,
            interimBody: "Open your browser to sign in to this network."),

        AlertDefinition(
            id: "vpn-dropped", title: "Your VPN disconnected",
            rules: [],   // raised from a vpn.active true→false transition
            dwell: 10, cooldown: 300, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: "Your traffic is no longer going through the VPN."),

        AlertDefinition(
            id: "clock-drift", title: "Your Mac's clock is wrong",
            rules: ["NT-1"],
            dwell: 0, cooldown: 43_200, resolves: true, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: ""),

        AlertDefinition(
            id: "ip-conflict", title: "IP address conflict",
            rules: ["DI-1", "DI-2"],
            dwell: 0, cooldown: 21_600, resolves: true, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: ""),

        AlertDefinition(
            id: "different-network", title: "This isn't the network you think",
            rules: [],   // raised from a gateway-MAC change under a known SSID
            dwell: 30, cooldown: 0, resolves: false, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: true,
            interimBody: "The Wi-Fi name is the same, but the router behind it is a different one."),

        AlertDefinition(
            id: "weak-wifi", title: "Weak Wi-Fi signal",
            rules: ["W1", "W2"],
            // The most nag-prone of the twelve: signal strength drifts all
            // day as a laptop moves around a house. Two minutes of dwell
            // and an hour of cooldown is what makes it survivable — it
            // should fire when you have settled somewhere bad, not while
            // you walk past the kitchen.
            dwell: 120, cooldown: 3600, resolves: true, scanOnly: false,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: "Checking how much the signal is costing you…"),

        AlertDefinition(
            id: "lease-expiring", title: "Network address expiring soon",
            rules: ["DH-1"],
            dwell: 0, cooldown: 21_600, resolves: false, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: ""),

        AlertDefinition(
            id: "slower-than-usual", title: "Slower than usual",
            rules: ["BL-1"],
            dwell: 0, cooldown: 43_200, resolves: false, scanOnly: true,
            suppressedByICMPFilter: false, oncePerNetwork: false,
            interimBody: ""),
    ]

    static func byID(_ id: String) -> AlertDefinition? { all.first { $0.id == id } }

    /// Alerts a monitor sample can raise, i.e. everything the between-scans
    /// probes actually measure.
    static var liveAlerts: [AlertDefinition] { all.filter { !$0.scanOnly } }

    /// Alerts only a full scan can observe. The monitor never claims these
    /// — it does not measure clock drift, ARP conflicts, DHCP leases or
    /// baseline regressions, and guessing at them would be inventing a
    /// verdict.
    static var scanAlerts: [AlertDefinition] { all.filter { $0.scanOnly } }
}
