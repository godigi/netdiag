import CoreWLAN
import Foundation

/// Finds the `netdiag` executable, and defines the environment every child
/// process gets.
///
/// This is more delicate than it looks. `netdiag` is normally a *symlink*
/// (`~/bin/netdiag` → the repo's `bin/netdiag`) whose first act is to
/// re-exec itself under Homebrew bash 5, because macOS still ships bash
/// 3.2. It then shells out to `python3`, `dig`, `nc`, `sntp` and friends.
///
/// A GUI app launched from Finder inherits almost nothing: `launchd` gives
/// it a minimal `PATH` that does not include `/opt/homebrew/bin`. Left
/// alone, the re-exec fails and netdiag exits 3 with "requires bash 5" —
/// which surfaces in the app as an empty dashboard and no explanation. So
/// every child gets an explicit PATH.
///
/// Resolution order (T7): user override → the CLI bundled inside this
/// app (`Contents/Resources/cli/bin/netdiag`, put there by `gui/Makefile`'s
/// `bundle` target) → `~/bin` → Homebrew prefixes → a PATH walk. The
/// bundled copy is checked right after the override, ahead of every
/// on-disk guess, because it is schema-matched to this exact build of the
/// app — a `~/bin/netdiag` from a different checkout could be an older or
/// newer CLI emitting JSON this app doesn't expect. The override still
/// wins over the bundle: it exists precisely so a developer working on a
/// dev checkout of the CLI can point the app at it instead of the copy
/// frozen inside the bundle at build time.
enum BinaryLocator {
    /// Injected into every child process. Homebrew first (Apple Silicon,
    /// then Intel), then the system directories the CLI's own helpers need.
    static let processPATH =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The CLI copy bundled inside this app by `gui/Makefile`'s `bundle`
    /// target. For a bare executable (`swift run`, the raw build product)
    /// `Bundle.main.resourceURL` is NOT nil — it resolves to the
    /// executable's own directory — so this returns a path that simply
    /// doesn't exist there; `resolve()`'s `isExecutableFile` check rejects
    /// it and the candidates below take over. Fail-safe by absence, not
    /// by nil.
    private static var bundledBinary: String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("cli/bin/netdiag").path
    }

    /// Where to look when the user has not set an override and no bundled
    /// copy was found, in order of how likely each is to be the copy they
    /// actually maintain.
    private static let candidates = [
        "\(NSHomeDirectory())/bin/netdiag",
        "/opt/homebrew/bin/netdiag",
        "/usr/local/bin/netdiag",
    ]

    /// Resolved path, or nil. Checked fresh each time rather than cached:
    /// a user who fixes a bad override in Settings should not have to
    /// relaunch the app to see it take effect.
    static func resolve() -> String? {
        let override = Defaults.binaryPath
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        if let bundled = bundledBinary, FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return searchPATH()
    }

    /// Last resort: walk the injected PATH ourselves rather than shelling
    /// out to `which`, which would need a shell that may not exist either.
    private static func searchPATH() -> String? {
        for dir in processPATH.split(separator: ":") {
            let candidate = "\(dir)/netdiag"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = processPATH
        // The CLI writes its log and history under $HOME. A GUI process has
        // one, but stating it explicitly means the app and a terminal run
        // demonstrably share ~/net-diag rather than probably sharing it.
        env["HOME"] = NSHomeDirectory()
        // The Wi-Fi name, when this app can see it and the CLI cannot.
        //
        // TCC attributes `ipconfig getsummary` and `wdutil` to those
        // binaries rather than to the .app that spawned them, so the child
        // reads back the literal string "<redacted>" on a machine where
        // `CWInterface.ssid()` here returns the real name. Left alone, the
        // CLI fires WI-1 — "macOS isn't telling netdiag which WiFi network
        // you're on" — in a window whose title bar is showing that exact
        // network, and every stored run is labelled "WiFi (SSID hidden by
        // macOS)".
        //
        // The CLI treats this strictly as a fallback: a name it read off
        // the link itself always wins, and it records `wifi.ssid_source`
        // either way, so nothing downstream has to trust us blindly. See
        // NETDIAG_SSID_HINT in lib/wifi.sh.
        //
        // No permission check here: without a Location grant `ssid()`
        // returns nil, which is exactly the case this skips. Cheap enough
        // to do per spawn — full checks are occasional and the monitor
        // spawns once for the life of the process.
        if let ssid = liveSSID() { env["NETDIAG_SSID_HINT"] = ssid }
        return env
    }

    /// The associated network's name from CoreWLAN, or nil when there
    /// isn't one to be had — Wi-Fi off, on ethernet, or Location not
    /// granted. Mirrors `NetdiagCoordinator.refreshLiveWiFi`'s interface
    /// lookup, including its fallback for builds where `interface()`
    /// returns nil while associated.
    private static func liveSSID() -> String? {
        let client = CWWiFiClient.shared()
        let iface = client.interface() ?? client.interfaces()?.first { $0.powerOn() }
        guard let name = iface?.ssid(), !name.isEmpty,
              !name.contains("<redacted>") else { return nil }
        return name
    }

    /// Human-readable explanation for the one failure a user can fix.
    /// Phrased as a setup problem, not a network problem — this is the app
    /// failing to find a tool, and saying anything about the network here
    /// would be a lie of exactly the kind the CLI is careful to avoid.
    ///
    /// Near-unreachable since T7: a properly bundled app always has
    /// `cli/bin/netdiag` inside it, so hitting this message means the
    /// bundle itself is broken (a build that skipped `make bundle`, or a
    /// user override pointing at a path that no longer exists) rather than
    /// "the user never installed the CLI" — but that's still a real state
    /// worth a truthful, actionable message rather than a dead link.
    static let missingBinaryMessage = """
        netdiag couldn't find the netdiag command-line tool. \
        Set its location in Settings, or install it with:
        curl -fsSL https://raw.githubusercontent.com/godigi/netdiag/main/install.sh | bash
        """
}
