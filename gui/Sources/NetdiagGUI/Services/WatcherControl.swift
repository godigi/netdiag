import Foundation

/// Toggles the launchd watcher — `netdiag --install-watcher` /
/// `--uninstall-watcher` — and reports whether it is loaded.
///
/// The watcher is what makes the history worth charting. Without it, the
/// store only grows when someone remembers to run netdiag; with it, a
/// `--quick` run lands every 15 minutes and the two-month view has actual
/// density. It stays optional because it is a background job that touches
/// the network on a timer, and that should be a choice.
///
/// The install and uninstall paths deliberately shell out to the CLI rather
/// than writing the plist here. The plist embeds the resolved script path
/// and the exact flag set, and having two places that decide those is how
/// they drift.
@MainActor
@Observable
final class WatcherControl {

    private(set) var isInstalled = false
    private(set) var isBusy = false
    private(set) var lastError: String?

    private static let label = "com.netdiag.watcher"

    func refresh() async {
        isInstalled = await Self.isLoaded()
    }

    func install() async {
        await toggle(argument: "--install-watcher", expecting: true)
    }

    func uninstall() async {
        await toggle(argument: "--uninstall-watcher", expecting: false)
    }

    private func toggle(argument: String, expecting: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await NetdiagRunner.run(depth: .quick, extraArguments: [argument])
        } catch {
            // Both watcher flags are mode dispatchers: they exit 0 before
            // the check battery runs, so --json never gets a chance to
            // print and the decode fails on success. Only a script error
            // (exit 3) is worth surfacing.
            if case NetdiagError.scriptError(let detail) = error {
                lastError = detail
                await refresh()
                return
            }
        }
        lastError = nil
        await refresh()
        // launchctl is not synchronous with the load; if the state hasn't
        // caught up, look once more rather than showing a stale toggle.
        if isInstalled != expecting {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        }
    }

    /// `launchctl list <label>` exits non-zero when the job is not loaded.
    /// Cheaper and more direct than parsing the full list, and it does not
    /// care whether the plist file happens to exist — a plist on disk that
    /// failed to load is exactly the state a "watcher installed" toggle
    /// must not claim.
    private static func isLoaded() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list", label]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
