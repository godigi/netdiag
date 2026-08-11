import Foundation

/// Loads and holds `netdiag --history`, applies the user's renames and
/// manual merges, and answers the questions HistoryView and NetworksView
/// ask of it.
///
/// The grouping itself is not decided here — helpers/history.py does that,
/// including the gateway+ISP bridge heuristic. What lives in this file is
/// the layer *on top*: the names a user assigned and the merges they made
/// by hand where the heuristic honestly could not decide. Those are
/// preferences, not measurements, so they belong in UserDefaults rather
/// than in the CLI's data.
@MainActor
@Observable
final class HistoryStore {

    private(set) var document: HistoryDocument = .empty
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?

    /// User-assigned display names, keyed by the group's stable key (the
    /// `mac:` component where one exists).
    private(set) var customNames: [String: String] = Defaults.networkNames
    /// Manual merges: member group key → the key it was merged into. The
    /// honest fallback for the cases the bridge heuristic left apart, since
    /// a wrong automatic merge silently corrupts a chart while a missing
    /// one is visible and fixable.
    private(set) var manualMerges: [String: String] = Defaults.networkMerges

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            document = try await NetdiagRunner.history()
            lastError = nil
            lastLoadedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Naming

    func displayName(for networkID: String) -> String {
        if let custom = customNames[canonicalID(networkID)], !custom.isEmpty { return custom }
        if let net = document.networks.first(where: { $0.id == canonicalID(networkID) }) {
            return net.label
        }
        return networkID
    }

    func rename(_ networkID: String, to name: String) {
        let key = canonicalID(networkID)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { customNames.removeValue(forKey: key) } else { customNames[key] = trimmed }
        Defaults.networkNames = customNames
    }

    // MARK: - Manual merge

    /// Follows the merge chain to the group a key ultimately belongs to.
    /// Bounded rather than recursive: a user who merges A→B and later B→A
    /// would otherwise hang the app on the next render.
    func canonicalID(_ networkID: String) -> String {
        var current = networkID
        var hops = 0
        while let parent = manualMerges[current], parent != current, hops < 16 {
            current = parent
            hops += 1
        }
        return current
    }

    func merge(_ source: String, into destination: String) {
        guard source != destination else { return }
        // Merge onto the destination's own canonical id, so merging into an
        // already-merged group joins the real group rather than creating a
        // second hop that has to be followed forever.
        manualMerges[source] = canonicalID(destination)
        Defaults.networkMerges = manualMerges
    }

    func unmerge(_ networkID: String) {
        manualMerges.removeValue(forKey: networkID)
        Defaults.networkMerges = manualMerges
    }

    // MARK: - Derived views

    /// Networks after manual merges are applied, largest first.
    var mergedNetworks: [HistoryDocument.Network] {
        var byID: [String: HistoryDocument.Network] = [:]
        for net in document.networks {
            let key = canonicalID(net.id)
            if var existing = byID[key] {
                existing.runCount += net.runCount
                // A merge is the user asserting an identity the data could
                // not establish. Mark the result synthesized for the same
                // reason the bridge heuristic does.
                existing.synthesized = true
                existing.bridgedFrom.append(net.id)
                existing.gateways = Array(Set(existing.gateways + net.gateways)).sorted()
                existing.isps = Array(Set(existing.isps + net.isps)).sorted()
                existing.ssids = Array(Set(existing.ssids + net.ssids)).sorted()
                existing.firstSeen = [existing.firstSeen, net.firstSeen].compactMap { $0 }.min()
                existing.lastSeen = [existing.lastSeen, net.lastSeen].compactMap { $0 }.max()
                for (k, v) in net.metricSamples { existing.metricSamples[k, default: 0] += v }
                for (k, v) in net.severityCounts { existing.severityCounts[k, default: 0] += v }
                byID[key] = existing
            } else {
                var copy = net
                copy.id = key
                byID[key] = copy
            }
        }
        return byID.values.sorted { $0.runCount > $1.runCount }
    }

    func runs(networkID: String?, window: HistoryWindow) -> [HistoryDocument.Run] {
        let cutoff = window.cutoff
        let wanted = networkID.map { canonicalID($0) }
        return document.runs.filter { run in
            if let wanted, canonicalID(run.networkID) != wanted { return false }
            if let cutoff, run.date < cutoff { return false }
            return true
        }
    }

    /// Points for one metric, skipping runs where it was not measured.
    ///
    /// Skipping rather than zero-filling is the whole difference between a
    /// chart and a lie: `speedtest.down_mbps` is absent from every one of
    /// the 1,926 legacy records here, and drawing those as zero would show
    /// two months of a dead connection.
    func series(metric: String, networkID: String?, window: HistoryWindow) -> [(Date, Double)] {
        runs(networkID: networkID, window: window)
            .compactMap { run in run.metrics[metric].map { (run.date, $0) } }
            .sorted { $0.0 < $1.0 }
    }

    /// How many runs in this window actually carry the metric. Rendered
    /// next to every chart, and the reason a metric with zero samples gets
    /// an explicit "no data" state rather than an empty axis: sparse series
    /// are the normal case in this store, not an edge case.
    func sampleCount(metric: String, networkID: String?, window: HistoryWindow) -> Int {
        runs(networkID: networkID, window: window).reduce(0) {
            $0 + ($1.metrics[metric] != nil ? 1 : 0)
        }
    }

    func metric(_ key: String) -> HistoryDocument.MetricDescriptor? {
        document.metrics.first { $0.key == key }
    }

    /// True the first time this network appears in the store. Drives the
    /// "scan a network you've never been on" trigger — and it is a question
    /// about *history*, so it is answered from history rather than from a
    /// separate list the app would have to keep in sync.
    func isFirstTimeSeen(_ networkID: String) -> Bool {
        let key = canonicalID(networkID)
        return !document.networks.contains { canonicalID($0.id) == key }
    }
}
