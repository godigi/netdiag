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

    /// One-time rewrite of keys recorded before the group-id join landed.
    /// Renames and seen-network entries were keyed by the raw sample id
    /// (`wifi:mac=AA:BB:…`), which never matches a `--history` group —
    /// the bug where an adopted Wi-Fi name showed on Home but not in the
    /// Networks tab. Rewrites `wifi:mac=X` / `lan:mac=X` to the group key
    /// (`mac:x`), lowercased, without clobbering a key that already
    /// exists. Idempotent: a second run finds nothing left to move.
    private static func migrateRawKeys(_ dict: [String: String]) -> [String: String] {
        var out = dict
        for (key, value) in dict {
            let mac: String
            if key.hasPrefix("wifi:mac=") { mac = String(key.dropFirst("wifi:mac=".count)) }
            else if key.hasPrefix("lan:mac=") { mac = String(key.dropFirst("lan:mac=".count)) }
            else { continue }
            let groupKey = "mac:\(mac.lowercased())"
            if out[groupKey] == nil { out[groupKey] = value }
            if groupKey != key { out.removeValue(forKey: key) }
        }
        return out
    }

    init() {
        // Reads first, migration second, so the migrated shape is what
        // both the store and Defaults hold from here on.
        let names = Self.migrateRawKeys(Defaults.networkNames)
        if names != Defaults.networkNames { Defaults.networkNames = names }
        customNames = names
        let seen = Self.migrateRawKeys(
            Dictionary(uniqueKeysWithValues: Defaults.seenNetworks.map { ($0, "1") }))
        let seenKeys = Set(seen.keys)
        if seenKeys != Defaults.seenNetworks { Defaults.seenNetworks = seenKeys }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            document = try await NetdiagRunner.history()
            lastError = nil
            lastLoadedAt = Date()
            // A fresh document invalidates every memoized median: the
            // store may have grown new runs, and stale numbers under a
            // "computed once" cache are worse than the repeated scan it
            // replaces.
            medianCache.removeAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Naming

    func displayName(for networkID: String) -> String {
        let key = canonicalID(networkID)
        if let custom = customNames[key], !custom.isEmpty { return custom }
        if let net = document.networks.first(where: { $0.id == key }) {
            // Prefer a recorded SSID (available only when Location was
            // granted at scan time) over the CLI's label, which is the
            // ISP name + " via " + gateway when no SSID was captured.
            if let ssid = net.ssids.first, !ssid.isEmpty { return ssid }
            return Self.cleanLabel(net.label)
        }
        return Self.cleanLabel(networkID)
    }

    /// Strips the " via <gateway>" suffix the CLI appends to a network
    /// label when it has no SSID to show — "SPACEX-STARLINK via
    /// 192.168.50.1" becomes "SPACEX-STARLINK". A presentation cleanup,
    /// not a diagnostic judgment: the full label stays in the document,
    /// and `haystack(for:)` in NetworksView still searches the raw value.
    static func cleanLabel(_ label: String) -> String {
        if let range = label.range(of: " via ") {
            return String(label[..<range.lowerBound])
        }
        return label
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
        // A merge changes which raw networks a canonical id stands for,
        // which is exactly what `median(metric:networkID:)` keys its cache
        // on — see its doc comment.
        medianCache.removeAll()
    }

    func unmerge(_ networkID: String) {
        manualMerges.removeValue(forKey: networkID)
        Defaults.networkMerges = manualMerges
        medianCache.removeAll()
    }

    // MARK: - Derived views

    /// The merge pass with no sort — the shared work both `mergedNetworks`
    /// and `mergedNetworksByRecency` need, factored out so neither pays for
    /// a sort the other wanted. O(networks) per call, not O(runs): the
    /// merge walks the document's network groups, not its runs.
    private var mergedNetworksUnsorted: [HistoryDocument.Network] {
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
        return Array(byID.values)
    }

    /// Networks after manual merges are applied, largest first.
    var mergedNetworks: [HistoryDocument.Network] {
        mergedNetworksUnsorted.sorted { $0.runCount > $1.runCount }
    }

    /// Networks after manual merges, most-recently-seen first — the order
    /// the Networks tab wants: you go to that tab to find the network you
    /// just left or the one you're on, not the one you've used the most over
    /// all time. Falls back to run-count when two networks share a
    /// `lastSeen` (e.g. runs recorded in the same second), and to name when
    /// even that ties, so the order is stable across renders rather than
    /// shuffling ties by dictionary iteration order. Sorts from
    /// `mergedNetworksUnsorted` rather than re-sorting `mergedNetworks`, so
    /// the recency path does not pay for the run-count sort it would throw
    /// away.
    var mergedNetworksByRecency: [HistoryDocument.Network] {
        mergedNetworksUnsorted.sorted { a, b in
            let la = a.lastSeenDate ?? .distantPast
            let lb = b.lastSeenDate ?? .distantPast
            if la != lb { return la > lb }
            if a.runCount != b.runCount { return a.runCount > b.runCount }
            return displayName(for: a.id) < displayName(for: b.id)
        }
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

    /// Newest-first runs that count as a check, across every network —
    /// `HistoryDocument.Run.isCheck` filters out `-only` measurements. Built
    /// for cold-launch hydration (`NetdiagCoordinator.hydrateFromHistoryIfNeeded`),
    /// which wants "the most recent real look at any network this app has
    /// seen", and for the "Recent checks" list a later task adds to Home.
    ///
    /// Sorted on the raw `ts` string, not `Run.date`: docs/JSON-SCHEMA.md
    /// fixes `timestamp` at ISO 8601 UTC with no fractional seconds, so
    /// lexicographic order on that string already equals chronological
    /// order — `bin/netdiag` is the store's only writer, and that equality
    /// has held over the full store this was verified against. Skipping the
    /// parse still matters even now that `Run.date` reads from
    /// `HistoryDocument.iso`, the formatter every call in this document
    /// shares: sorting ~2,000 runs invokes the comparator roughly n·log₂n
    /// times, each side parsing a date, and the parsing itself — not just
    /// the `ISO8601DateFormatter()` construction the shared instance
    /// removed — is the cost. Measured 5.3 s through a fresh formatter per
    /// call, 0.6 ms for the lexicographic compare below; the shared
    /// formatter cuts the construction share of that 5.3 s but leaves
    /// ~44,000 parse calls this comparator has no need to make.
    func recentChecks(limit: Int) -> [HistoryDocument.Run] {
        Array(document.runs.filter(\.isCheck).sorted { ($0.ts ?? "") > ($1.ts ?? "") }.prefix(limit))
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

    /// Returns the most recent speed test measurement from history.
    func latestSpeedTest(for networkID: String? = nil) -> (down: Double, up: Double?, date: Date)? {
        let canonicalTarget = networkID.map { canonicalID($0) }
        let runs = document.runs.sorted { ($0.ts ?? "") > ($1.ts ?? "") }
        
        if let canonicalTarget {
            for run in runs {
                if canonicalID(run.networkID) == canonicalTarget || run.networkID == networkID {
                    let down = run.metrics["speed_down_mbps"] ?? run.metrics["speedtest.down_mbps"]
                    if let down {
                        let up = run.metrics["speed_up_mbps"] ?? run.metrics["speedtest.up_mbps"]
                        return (down, up, run.date)
                    }
                }
            }
        }
        
        for run in runs {
            let down = run.metrics["speed_down_mbps"] ?? run.metrics["speedtest.down_mbps"]
            if let down {
                let up = run.metrics["speed_up_mbps"] ?? run.metrics["speedtest.up_mbps"]
                return (down, up, run.date)
            }
        }
        return nil
    }

    // MARK: - Medians

    /// `median(metric:networkID:)`'s memo, keyed by canonical network id
    /// then metric key. The inner value is itself optional — a network
    /// with no samples for a metric memoizes `nil` too, so that case does
    /// not re-scan `runs()` on every redraw either — which is why lookups
    /// below unwrap it with `if let` rather than `??`: one `if let` peels
    /// exactly the "have we computed this at all" layer off, leaving the
    /// possibly-nil result underneath untouched. Cleared in `load()` and
    /// in `merge()`/`unmerge()`, the two places what a canonical id stands
    /// for can change.
    ///
    /// `@ObservationIgnored` because `median()` writes this during view
    /// bodies: a cache fill must not look like observable state changing,
    /// or a second view calling `median()` could invalidate the first
    /// mid-render for what is semantically a read.
    @ObservationIgnored
    private var medianCache: [String: [String: Double?]] = [:]

    /// The median for one metric on one network, computed once per loaded
    /// document rather than by every row on every render.
    ///
    /// Before this existed, `NetworksView` called `runs(networkID:window:)`
    /// — an O(runs) scan and sort — from inside its per-row body, over
    /// roughly 2,000 runs on the author's own machine, once per network row
    /// per redraw.
    ///
    /// Prefers the CLI's own `metric_stats.median` — the same population
    /// arithmetic `--show`'s `comparison` already uses
    /// (`helpers/history.py`'s `population_stats`), reused here rather than
    /// re-derived in Swift — for a network that maps onto exactly one raw
    /// `--history` group. A manually merged network (`merge(_:into:)`)
    /// combines runs the CLI still reports as separate groups, so their
    /// per-group medians cannot be combined into one without redoing the
    /// arithmetic; that case, and an old CLI with no `metric_stats` at all,
    /// fall back to the local computation this file always did.
    func median(metric: String, networkID: String) -> Double? {
        let key = canonicalID(networkID)
        if let cached = medianCache[key]?[metric] { return cached }
        let value = computeMedian(metric: metric, canonicalID: key)
        medianCache[key, default: [:]][metric] = value
        return value
    }

    private func computeMedian(metric: String, canonicalID key: String) -> Double? {
        let raw = document.networks.filter { canonicalID($0.id) == key }
        if raw.count == 1, let stat = raw[0].stat(for: metric), let median = stat.median {
            return median
        }
        return localMedian(metric: metric, networkID: key)
    }

    /// The exhaustive fallback: a full scan and sort of the metric's own
    /// series. That undersells the gap with `metric_stats`: below
    /// `THRESH_COMPARE_MIN_SAMPLES` the CLI returns `null` on purpose
    /// (docs/JSON-SCHEMA.md — it withholds a number "stated with more
    /// confidence than the sample supports"), and this fallback computes
    /// that same median anyway, from as few as 2 readings. That's not this
    /// file overriding the CLI's judgement; it's preserved legacy
    /// behavior — `NetworksView` always computed it this way, before
    /// `metric_stats` existed to refuse — and it is still the only option
    /// for a manually merged network or a CLI old enough to have no
    /// `metric_stats` at all.
    private func localMedian(metric: String, networkID: String) -> Double? {
        let values = runs(networkID: networkID, window: .all)
            .compactMap { $0.metrics[metric] }
            .sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}
