import Foundation
import os

/// Holds `netdiag --rules-catalog` in memory once it's been fetched, and
/// answers the question every `RuleChip` and every category-driven report
/// row asks: "does this rule id have plain-language prose?"
///
/// ── `@MainActor @Observable`, not an `actor` ────────────────────────────
/// `CapabilityStore` is the other CLI-handshake cache in this app and it's
/// an `actor` — but its callers are non-view service code (`NetdiagRunner`,
/// `MonitorStream`) making gating decisions off whatever thread happens to
/// be running, so isolating its state from the main actor is the whole
/// point. This store's callers are the opposite: `RuleChip` and every
/// `RunReportView` row read `catalog` straight out of a view body, on
/// every render, already on `@MainActor`. Making this an `actor` too would
/// force each of those into its own `.task { await … }` just to read a
/// value that — once loaded — never needs isolating from anything but
/// itself; `SettingsView`'s `@State private var capabilities` (see that
/// file's header) is exactly the workaround that would multiply across
/// every call site here. `@Observable` on `@MainActor` is what
/// `HistoryStore`, `RunDetailStore` and `AlertEngine` already use for the
/// same reason: a store views read synchronously and that updates them
/// reactively when the async fetch behind it finishes.
///
/// ── Two-tier fetch, cheapest first ──────────────────────────────────────
/// 1. A file this exact CLI version already wrote to Application Support
///    (`rules-catalog-<version>.json`) — no process spawn, so a warm
///    launch never blocks a chip's first paint on running the CLI again.
/// 2. `netdiag --rules-catalog` itself, on a cold launch or after the
///    resolved CLI's version has changed, persisted back to that same
///    file for next time.
///
/// Gated on `CapabilityStore.Feature.rulesCatalog` (T8) and on the
/// handshake actually naming a version — an old CLI, or one whose
/// `--capabilities` couldn't be read, degrades to `catalog == nil` and
/// every consumer's documented fallback. Never a thrown `cliTooOld`: the
/// plain-language layer is additive per CLAUDE.md, not something a run
/// needs to proceed.
@MainActor
@Observable
final class RulesCatalogStore {

    private(set) var catalog: RulesCatalog?
    private(set) var isLoading = false

    /// The CLI version `catalog` was fetched for — `nil` until the first
    /// successful fetch. Compared against the handshake's current version
    /// on every `refresh()` so a CLI upgraded (or an override pointed
    /// somewhere else) in place is noticed instead of the stale in-memory
    /// catalog being trusted forever.
    private var loadedForVersion: String?
    private var refreshTask: Task<Void, Never>?

    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "rulescatalog")

    /// Cheap to call from every consumer's `.task` / `.onAppear` — a no-op
    /// once a fetch for the current version is in flight or already done.
    /// The version comparison itself still happens inside `refresh()`, not
    /// here, so calling this again later (a new `RuleChip` appearing after
    /// the first one already resolved) stays a no-op right up until the
    /// resolved CLI's version actually changes.
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
    /// version's catalog. Safe to call repeatedly: `CapabilityStore` itself
    /// only re-probes when the resolved binary path changed, so most calls
    /// here cost one already-cached actor round trip and nothing else.
    /// Public so `SettingsView`'s "Re-check" — the one place in this app a
    /// user explicitly asks "did the CLI change?" — can ask this store the
    /// same question at the same moment, rather than waiting for some
    /// other view to happen to call `ensureLoaded()` again.
    func refresh() async {
        guard await CapabilityStore.shared.supports(.rulesCatalog) else {
            catalog = nil
            loadedForVersion = nil
            return
        }
        guard case .modern(let caps) = await CapabilityStore.shared.current(),
              let version = caps.version, !version.isEmpty else {
            catalog = nil
            loadedForVersion = nil
            return
        }
        guard version != loadedForVersion || catalog == nil else { return }

        isLoading = true
        defer { isLoading = false }

        if let cached = Self.readFromDisk(version: version) {
            catalog = cached
            loadedForVersion = version
            log.debug("rules catalog v\(version, privacy: .public) loaded from disk cache")
            return
        }

        guard let (out, _, status) = try? await NetdiagRunner.execute(
            arguments: ["--rules-catalog"]), status == 0,
            let data = out.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(RulesCatalog.self, from: data) else {
            log.error("rules catalog probe failed or didn't decode for v\(version, privacy: .public)")
            return
        }
        catalog = decoded
        loadedForVersion = version
        Self.persist(rawJSON: out, version: version)
        log.debug("rules catalog v\(version, privacy: .public) fetched from the CLI and cached")
    }

    // MARK: - Disk cache
    //
    // ~/Library/Application Support/<bundle id>/rules-catalog-<version>.json
    // — one file per CLI version ever seen, so a downgrade (or a second
    // machine's older CLI read over a synced ~/Library) finds its own
    // cache untouched rather than colliding with a newer one. Nothing
    // prunes old versions' files; they're a few KB of JSON each and the
    // set of versions one Mac ever runs this app against is small.

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "me.brianfreeman.netdiag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFileURL(version: String) -> URL? {
        // Version strings come from the CLI's own `--capabilities`
        // (`major.minor.patch`), never user input, so no sanitizing beyond
        // what a semver string already satisfies as a filename.
        cacheDirectory?.appendingPathComponent("rules-catalog-\(version).json")
    }

    private static func readFromDisk(version: String) -> RulesCatalog? {
        guard let url = cacheFileURL(version: version),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RulesCatalog.self, from: data)
    }

    /// Written atomically and verbatim — the exact bytes `--rules-catalog`
    /// printed, not a re-encode of the decoded model, for the same reason
    /// `RunResult.rawJSON` keeps the CLI's own bytes: a future field this
    /// build doesn't parse yet still round-trips through the cache once a
    /// newer build reads the same file.
    private static func persist(rawJSON: String, version: String) {
        guard let url = cacheFileURL(version: version),
              let data = rawJSON.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
