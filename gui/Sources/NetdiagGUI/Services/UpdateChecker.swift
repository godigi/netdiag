import Foundation
import SwiftUI
import os.log

/// Automatic update checker and installer for Netdiag GUI.
///
/// Periodically (or on-demand) queries GitHub Releases API for `godigi/netdiag`,
/// evaluates whether a newer semantic version is available, and provides
/// one-click downloading, installation, and relaunching.
@MainActor
@Observable
final class UpdateChecker {
    private let log = Logger(subsystem: "com.godigi.netdiag", category: "UpdateChecker")
    private let releaseAPI = URL(string: "https://api.github.com/repos/godigi/netdiag/releases/latest")!
    private let releaseWebFallback = URL(string: "https://github.com/godigi/netdiag/releases/latest")!

    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double = 0.0
    var hasUpdate = false
    var availableRelease: GitHubRelease?
    var statusMessage: String = "Up to date"
    var lastCheckedDate: Date? { Defaults.lastUpdateCheck }
    var errorMessage: String?

    init() {
        if let last = Defaults.lastUpdateCheck {
            log.debug("UpdateChecker initialized. Last checked: \(last.description, privacy: .public)")
        }
    }

    /// Checks for updates against GitHub Releases.
    /// - Parameter manual: If true, updates statusMessage explicitly for user feedback.
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        if manual { statusMessage = "Checking for updates…" }

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }
            do {
                var request = URLRequest(url: self.releaseAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Netdiag-App/\(Defaults.appVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if http.statusCode == 404 {
                    // No releases published yet on the repo
                    self.hasUpdate = false
                    self.statusMessage = "You're up to date! (v\(Defaults.appVersion))"
                    Defaults.lastUpdateCheck = Date()
                    return
                }

                guard http.statusCode == 200 else {
                    throw URLError(.init(rawValue: http.statusCode))
                }

                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)
                let currentVersion = SemanticVersion(Defaults.appVersion)
                let remoteVersion = SemanticVersion(release.cleanVersion)

                Defaults.lastUpdateCheck = Date()

                if remoteVersion > currentVersion {
                    self.hasUpdate = true
                    self.availableRelease = release
                    self.statusMessage = "netdiag v\(release.cleanVersion) is available!"
                    self.log.info("New release found: v\(release.cleanVersion) (current: v\(Defaults.appVersion))")
                } else {
                    self.hasUpdate = false
                    self.availableRelease = nil
                    self.statusMessage = "You're up to date! (v\(Defaults.appVersion))"
                    self.log.debug("App is up to date: v\(Defaults.appVersion)")
                }
            } catch {
                self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if manual {
                    self.errorMessage = "Could not check for updates."
                    self.statusMessage = "Check failed"
                }
            }
        }
    }

    /// Background check executed daily if enabled in settings.
    func performDailyCheck() {
        guard Defaults.autoCheckUpdates else { return }
        let now = Date()
        if let last = Defaults.lastUpdateCheck {
            let elapsed = now.timeIntervalSince(last)
            // 24 hours = 86,400 seconds
            if elapsed < 86_400 {
                return
            }
        }
        checkForUpdates(manual: false)
    }

    /// Downloads and installs the latest release update, then relaunches the app.
    func downloadAndInstallUpdate() {
        guard let release = availableRelease else {
            openReleasePage()
            return
        }

        // Look for installable asset (e.g. Netdiag.app.zip, Netdiag.zip, Netdiag.dmg)
        let asset = release.assets.first(where: { $0.isInstallableArchive })
        guard let downloadURL = asset?.browserDownloadUrl else {
            // No direct archive asset attached: open release page directly
            openReleasePage()
            return
        }

        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.1
        statusMessage = "Downloading v\(release.cleanVersion)…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isDownloading = false }
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NetdiagUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let (downloadedURL, _) = try await URLSession.shared.download(from: downloadURL)
                self.downloadProgress = 0.7
                self.statusMessage = "Installing update…"

                let archivePath = tempDir.appendingPathComponent(asset?.name ?? "update.zip")
                try FileManager.default.moveItem(at: downloadedURL, to: archivePath)

                // Unpack archive
                let extractDir = tempDir.appendingPathComponent("Extracted")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let isZip = archivePath.pathExtension.lowercased() == "zip"
                if isZip {
                    let ditto = Process()
                    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    ditto.arguments = ["-xk", archivePath.path, extractDir.path]
                    try ditto.run()
                    ditto.waitUntilExit()

                    // Locate Netdiag.app inside extractDir
                    let fileManager = FileManager.default
                    let contents = try fileManager.contentsOfDirectory(atPath: extractDir.path)
                    var appPath: String?
                    if contents.contains("Netdiag.app") {
                        appPath = extractDir.appendingPathComponent("Netdiag.app").path
                    } else {
                        // Search subdirectories
                        for item in contents {
                            let sub = extractDir.appendingPathComponent(item)
                            if sub.lastPathComponent == "Netdiag.app" {
                                appPath = sub.path
                                break
                            }
                        }
                    }

                    if let appPath {
                        self.downloadProgress = 1.0
                        self.statusMessage = "Relaunching…"
                        self.replaceAndRelaunch(withAppAt: appPath)
                        return
                    }
                }

                // If unpack did not locate a direct .app, open release page
                self.openReleasePage()
            } catch {
                self.log.error("Installation failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Failed to install update."
                self.openReleasePage()
            }
        }
    }

    /// Opens the GitHub release page in default browser.
    func openReleasePage() {
        let url = availableRelease?.htmlUrl ?? releaseWebFallback
        NSWorkspace.shared.open(url)
    }

    /// Spawns a background script that waits for current process to exit, swaps /Applications/Netdiag.app, and relaunches.
    private func replaceAndRelaunch(withAppAt newAppPath: String) {
        let script = """
        sleep 1
        rm -rf /Applications/Netdiag.app
        cp -R "\(newAppPath)" /Applications/Netdiag.app
        open /Applications/Netdiag.app
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()

        NSApp.terminate(nil)
    }
}
