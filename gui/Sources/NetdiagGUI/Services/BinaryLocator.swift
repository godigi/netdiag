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
enum BinaryLocator {
    /// Injected into every child process. Homebrew first (Apple Silicon,
    /// then Intel), then the system directories the CLI's own helpers need.
    static let processPATH =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Where to look when the user has not set an override, in order of
    /// how likely each is to be the copy they actually maintain.
    private static let candidates = [
        "\(NSHomeDirectory())/bin/netdiag",
        "/opt/homebrew/bin/netdiag",
        "/usr/local/bin/netdiag",
        "\(NSHomeDirectory())/Documents/AI-Workspace/netdiag/bin/netdiag",
    ]

    /// Resolved path, or nil. Checked fresh each time rather than cached:
    /// a user who fixes a bad override in Settings should not have to
    /// relaunch the app to see it take effect.
    static func resolve() -> String? {
        let override = Defaults.binaryPath
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
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
        return env
    }

    /// Human-readable explanation for the one failure a user can fix.
    /// Phrased as a setup problem, not a network problem — this is the app
    /// failing to find a tool, and saying anything about the network here
    /// would be a lie of exactly the kind the CLI is careful to avoid.
    static let missingBinaryMessage = """
        netdiag couldn't find the netdiag command-line tool. \
        Set its location in Settings, or install it with:
        curl -fsSL https://raw.githubusercontent.com/…/install.sh | bash
        """
}
