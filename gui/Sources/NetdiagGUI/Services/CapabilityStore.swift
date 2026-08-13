import Foundation

/// Probes `netdiag --capabilities` once per *resolved binary path* and
/// remembers the answer — the compatibility handshake every call site
/// that relies on `--monitor`, `--history`, `--show` or `--progress`
/// consults before trusting the CLI it found.
///
/// Replaces `NetdiagRunner`'s old `ProgressSupport` actor, which asked
/// only one narrower question ("does this CLI understand `--progress`?")
/// by checking its exit status. `--progress` support is still answered
/// that same way here — it is the fallback for a CLI too old to have
/// `--capabilities` at all — but every other feature this app cares about
/// now goes through the one handshake instead of a second bespoke probe.
///
/// ── Why keyed on path, not asked once ever ──────────────────────────
/// `BinaryLocator.resolve()` is deliberately uncached (see its header) so
/// a Settings override takes effect the moment it's typed. A capability
/// cache that never re-probed would defeat that: fix a bad override, and
/// the app would go on treating the CLI it now points at as whatever the
/// *previous* one answered. Keying the cache on the resolved path — and
/// re-probing whenever that path changes — is what lets the override flow
/// work without an app relaunch, the same property `resolve()` itself
/// exists for.
actor CapabilityStore {
    static let shared = CapabilityStore()

    /// The CLI version this exact app build requires. Reads `AppVersion`
    /// rather than a literal — see that type's header for why the two
    /// numbers are guaranteed to agree — so there is exactly one place
    /// that decides what "too old" means, not one literal here and
    /// another beside every message that cites it.
    static var requiredVersion: String { AppVersion.raw }

    /// A feature name from docs/JSON-SCHEMA.md's `--capabilities`
    /// `features` array. All but `rulesCatalog` are gated on today;
    /// `rulesCatalog` is declared ahead of the task that adds the app's
    /// `--rules-catalog` consumer, so that task gates without touching
    /// this enum.
    enum Feature: String {
        case progress
        case monitor
        case history
        case show
        case rulesCatalog = "rules-catalog"
    }

    private var resolvedPath: String?
    private var state: CapabilityState = .unavailable
    /// The in-flight probe, if one is running, keyed by the path it's
    /// probing. An `actor` still admits reentrancy at every `await`
    /// inside one of its own methods — two calls to `current()` that both
    /// arrive before the first probe finishes would otherwise both see no
    /// cached answer yet and both spawn a `--capabilities` child, exactly
    /// the hazard the old `ProgressSupport` actor's header described (and,
    /// keyed on a plain `Bool?` rather than a `Task`, didn't actually
    /// close). Memoizing the `Task` itself — not just its eventual result
    /// — closes that window: the second caller awaits the first caller's
    /// task instead of starting its own.
    private var probing: (path: String?, task: Task<CapabilityState, Never>)?

    /// The current answer, re-probing if the resolved binary path has
    /// changed since the last call.
    func current() async -> CapabilityState {
        let resolved = BinaryLocator.resolve()
        if let probing, probing.path == resolved { return await probing.task.value }
        if resolved == resolvedPath { return state }
        return await beginProbe(path: resolved)
    }

    /// Forces a fresh probe of whatever path is resolved right now, even
    /// if it matches what's cached. The About section's "Re-check"
    /// button: a CLI updated in place at a path an override already
    /// pointed at would otherwise never be re-read.
    func recheck() async -> CapabilityState {
        await beginProbe(path: BinaryLocator.resolve())
    }

    /// True when the resolved CLI's handshake says — or its exit-3
    /// silence implies — that it has `feature`.
    func supports(_ feature: Feature) async -> Bool {
        supported(feature, in: await current())
    }

    /// Throws `NetdiagError.cliTooOld` when `feature` isn't there. Every
    /// gated call site (`NetdiagRunner.history()`/`.show()`,
    /// `MonitorStream.start()`) funnels through this instead of checking
    /// `supports(_:)` and composing its own message, so there is exactly
    /// one place that turns "unsupported" into the actionable string.
    func requireSupport(for feature: Feature) async throws {
        let state = await current()
        guard !supported(feature, in: state) else { return }
        let found: String? = if case .modern(let caps) = state { caps.version } else { nil }
        throw NetdiagError.cliTooOld(found: found, needs: Self.requiredVersion)
    }

    private func supported(_ feature: Feature, in state: CapabilityState) -> Bool {
        switch state {
        case .modern(let caps):
            return caps.supports(feature.rawValue)
        case .legacy(let supportsProgress):
            return feature == .progress ? supportsProgress : false
        case .unavailable:
            return false
        }
    }

    // MARK: - Probing

    private func beginProbe(path: String?) async -> CapabilityState {
        let task = Task { await Self.probe() }
        probing = (path, task)
        let result = await task.value
        // Only publish if nothing newer superseded us while this was in
        // flight — a rapid override change (this probe for the old path
        // still running when a probe for the new path starts) must not
        // let a stale answer overwrite a fresher one.
        if probing?.task == task {
            resolvedPath = path
            state = result
            probing = nil
        }
        return result
    }

    private static func probe() async -> CapabilityState {
        guard let (out, _, status) = try? await NetdiagRunner.execute(
            arguments: ["--capabilities"]) else { return .unavailable }
        if status == 0 {
            guard let data = out.data(using: .utf8),
                  let caps = try? JSONDecoder().decode(CLICapabilities.self, from: data) else {
                return .unavailable
            }
            return .modern(caps)
        }
        guard status == 3 else { return .unavailable }
        // The CLI's answer to a flag it has never heard of (bin/netdiag's
        // catch-all `-*)` branch) — exactly how every version before
        // commit 85bc9b4, this handshake's own introduction, answers
        // `--capabilities` itself. Fall back to the one narrower question
        // a GUI already knew how to ask an old CLI.
        let progressResult = try? await NetdiagRunner.execute(
            arguments: ["--progress", "--help"])
        return .legacy(supportsProgress: progressResult?.2 == 0)
    }
}
