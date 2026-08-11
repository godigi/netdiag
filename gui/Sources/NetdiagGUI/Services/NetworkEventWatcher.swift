import Foundation
import CoreWLAN
import Network
import os

/// Instant notification that the network changed.
///
/// The monitor loop would find this too, on its next cycle — up to ten
/// seconds later, or five on a degraded link. That is far too slow for the
/// thing it gates: joining a new network should update the flag, trigger a
/// public-IP refresh, open a 30-second alert grace period, and (for a
/// never-seen network) kick off a scan. Ten seconds of stale country flag
/// after switching networks reads as a broken app.
///
/// Two sources, because neither sees everything:
///   * `CWWiFiClient` fires on SSID/BSSID/link changes — the Wi-Fi-specific
///     events, including a roam between two access points on the same SSID,
///     which is invisible at the IP layer.
///   * `NWPathMonitor` fires on interface and VPN transitions — plugging in
///     ethernet, a VPN coming up or dropping, losing the link entirely.
@MainActor
@Observable
final class NetworkEventWatcher: NSObject {

    enum Event: Sendable, Equatable {
        case ssidChanged(String?)
        case bssidChanged(String?)
        case linkChanged
        case pathChanged(satisfied: Bool, usesVPN: Bool)
    }

    private(set) var lastEventAt: Date?
    private(set) var pathSatisfied = true
    private(set) var pathUsesVPN = false

    var onEvent: ((Event) -> Void)?

    private let wifiClient = CWWiFiClient.shared()
    private var pathMonitor: NWPathMonitor?
    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "netwatch")

    func start() {
        wifiClient.delegate = self
        // Each of these is a separate registration; CoreWLAN does not
        // deliver one without asking for it.
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .bssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let vpn = path.availableInterfaces.contains { $0.type == .other }
            Task { @MainActor in
                self?.handlePath(satisfied: satisfied, usesVPN: vpn)
            }
        }
        monitor.start(queue: DispatchQueue(label: "me.brianfreeman.netdiag.path"))
        pathMonitor = monitor
    }

    func stop() {
        try? wifiClient.stopMonitoringAllEvents()
        wifiClient.delegate = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePath(satisfied: Bool, usesVPN: Bool) {
        // NWPathMonitor is chatty — it re-reports the same path on every
        // interface flap. Only forward real transitions, or the alert
        // engine's 30-second grace window would be permanently open and no
        // alert would ever fire.
        guard satisfied != pathSatisfied || usesVPN != pathUsesVPN else { return }
        pathSatisfied = satisfied
        pathUsesVPN = usesVPN
        emit(.pathChanged(satisfied: satisfied, usesVPN: usesVPN))
    }

    fileprivate func emit(_ event: Event) {
        lastEventAt = Date()
        log.debug("network event: \(String(describing: event), privacy: .public)")
        onEvent?(event)
    }

    /// True while the network is still settling. DHCP, DNS and the default
    /// route all land a beat apart, so probes fired in the first seconds
    /// after a switch measure a half-configured stack — which is why the
    /// alert engine treats this as a global suppressor rather than a hint.
    func withinGracePeriod(_ seconds: TimeInterval = 30) -> Bool {
        guard let lastEventAt else { return false }
        return Date().timeIntervalSince(lastEventAt) < seconds
    }
}

// CoreWLAN calls these on its own queue.
extension NetworkEventWatcher: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName name: String) {
        Task { @MainActor in
            emit(.ssidChanged(CWWiFiClient.shared().interface(withName: name)?.ssid()))
        }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName name: String) {
        Task { @MainActor in
            emit(.bssidChanged(CWWiFiClient.shared().interface(withName: name)?.bssid()))
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName name: String) {
        Task { @MainActor in emit(.linkChanged) }
    }
}
