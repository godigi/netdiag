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

    /// Requests authorization, then falls back to System Settings if the
    /// request produced no visible change within ~1.5 s.
    ///
    /// For a menu-bar (LSUIElement) app, `requestWhenInUseAuthorization()`
    /// frequently shows no prompt at all — macOS silently declines to
    /// present one for an app with no Dock icon or frontmost window in
    /// some states. Without this fallback the "Allow" button reads as
    /// dead: the user clicks it, nothing visibly happens, and there is no
    /// second path forward. `refresh()` alone can't detect "no prompt
    /// appeared" — it can only report the status *after* checking, which
    /// is indistinguishable from "the user is still looking at a prompt
    /// that will resolve in a moment" without the wait below.
    ///
    /// Only meaningful from `.notDetermined` — denied/restricted already
    /// has its own path straight to `openSystemSettings()`, which every
    /// caller keeps handling itself before ever reaching here, and
    /// authorized has no button to click in the first place.
    func requestOrOpenSettings() {
        guard status == .notDetermined else { return }
        let statusBeforeRequest = status
        log.debug("requesting when-in-use location authorization")
        locationManager.requestWhenInUseAuthorization()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            self.refresh()
            if self.status == statusBeforeRequest {
                self.log.debug("no location prompt appeared within 1.5s; opening System Settings")
                self.openSystemSettings()
            }
        }
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
