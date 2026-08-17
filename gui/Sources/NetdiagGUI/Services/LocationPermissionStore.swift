import Foundation
import CoreLocation
import AppKit
import os

/// Manages macOS Location Services authorization state for netdiag.
///
/// ── Why this exists ───────────────────────────────────────────────────
/// macOS restricts Wi-Fi network names (SSID) and router hardware addresses
/// (BSSID) behind Location Services authorization because BSSIDs can be used
/// to determine physical location via global databases.
///
/// Netdiag uses this permission solely to display your active Wi-Fi name and
/// unredact local radio diagnostics. Hop differential testing (Gateway vs ISP)
/// works 100% without location permissions, but when permissions are denied
/// or revoked, the UI surfaces guidance and a dashboard warning banner.
@MainActor
@Observable
final class LocationPermissionStore: NSObject, CLLocationManagerDelegate {

    private(set) var status: CLAuthorizationStatus = .notDetermined
    private let locationManager = CLLocationManager()
    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "location")

    override init() {
        super.init()
        self.status = locationManager.authorizationStatus
        locationManager.delegate = self
    }

    var isAuthorized: Bool {
        switch status {
        case .authorizedAlways, .authorized:
            return true
        default:
            return false
        }
    }

    var isDeniedOrRestricted: Bool {
        switch status {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    var isNotDetermined: Bool {
        status == .notDetermined
    }

    func refresh() {
        status = locationManager.authorizationStatus
    }

    func requestAuthorization() {
        log.debug("requesting when-in-use location authorization")
        locationManager.requestWhenInUseAuthorization()
        refresh()
    }

    /// Opens macOS System Settings directly to Privacy & Security -> Location Services.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        // Fallback to general System Settings if specific pane fails
        if let fallback = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(fallback)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
            self.log.info("location authorization status changed: \(String(describing: newStatus.rawValue), privacy: .public)")
        }
    }
}
