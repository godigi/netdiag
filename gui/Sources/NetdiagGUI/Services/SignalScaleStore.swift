import Foundation
import os

/// Holds `netdiag --signal-scale` in memory once it's been fetched — the
/// CLI's own Excellent/Good/Fair/Weak bands, so the Wi-Fi cell can show a
/// word instead of a bare dBm number. Same shape as `RulesCatalogStore`
/// (that file's header explains the `@MainActor @Observable`-not-`actor`
/// choice; it applies here for the identical reason: `DropdownView` and
/// `HomeView` both read `scale` synchronously from a view body, on every
/// render), same two-tier fetch (an Application Support cache keyed by
/// CLI version, then the CLI itself), same gating on
/// `CapabilityStore.Feature` and a resolved version, same "never throws,
/// degrades to `scale == nil`" contract — the four bands are additive
/// polish per CLAUDE.md, not something a Wi-Fi reading needs to proceed.
@MainActor
@Observable
final class SignalScaleStore {

    private(set) var scale: SignalScale?
    private(set) var isLoading = false

    private var loadedForVersion: String?
    private var refreshTask: Task<Void, Never>?

    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "signalscale")

    /// Cheap to call from every consumer's `.task` / `.onAppear` — see
    /// `RulesCatalogStore.ensureLoaded()`'s identical header.
    func ensureLoaded() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            guard let self else { return }
            self.refreshTask = nil
        }
    }

    /// Re-probes the handshake and, if the version it reports differs from
    /// `loadedForVersion` (or nothing has loaded yet), fetches that
    /// version's scale. Safe to call repeatedly — see
    /// `RulesCatalogStore.refresh()`'s identical reasoning.
    func refresh() async {
        guard await CapabilityStore.shared.supports(.signalScale) else {
            scale = nil
            loadedForVersion = nil
            return
        }
        guard case .modern(let caps) = await CapabilityStore.shared.current(),
              let version = caps.version, !version.isEmpty else {
            scale = nil
            loadedForVersion = nil
            return
        }
        guard version != loadedForVersion || scale == nil else { return }

        isLoading = true
        defer { isLoading = false }

        if let cached = Self.readFromDisk(version: version) {
            scale = cached
            loadedForVersion = version
            log.debug("signal scale v\(version, privacy: .public) loaded from disk cache")
            return
        }

        guard let (out, _, status) = try? await NetdiagRunner.execute(
            arguments: ["--signal-scale"]), status == 0,
            let data = out.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SignalScale.self, from: data) else {
            log.error("signal scale probe failed or didn't decode for v\(version, privacy: .public)")
            return
        }
        scale = decoded
        loadedForVersion = version
        Self.persist(rawJSON: out, version: version)
        log.debug("signal scale v\(version, privacy: .public) fetched from the CLI and cached")
    }

    // MARK: - Disk cache
    //
    // ~/Library/Application Support/<bundle id>/signal-scale-<version>.json
    // — see RulesCatalogStore's identical cache for why one file per
    // version, never pruned.

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "me.brianfreeman.netdiag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFileURL(version: String) -> URL? {
        cacheDirectory?.appendingPathComponent("signal-scale-\(version).json")
    }

    private static func readFromDisk(version: String) -> SignalScale? {
        guard let url = cacheFileURL(version: version),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SignalScale.self, from: data)
    }

    /// Written atomically and verbatim — see `RulesCatalogStore.persist`'s
    /// identical reasoning: the exact bytes the CLI printed, not a
    /// re-encode of the decoded model.
    private static func persist(rawJSON: String, version: String) {
        guard let url = cacheFileURL(version: version),
              let data = rawJSON.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
