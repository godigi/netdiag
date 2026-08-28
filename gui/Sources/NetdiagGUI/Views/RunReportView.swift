import SwiftUI
import AppKit

/// The report card: one row per thing that was measured, then the CLI's own
/// prose about what it means.
///
/// One view for the run that just finished and for a run pulled out of the
/// store. Two would drift, and the stored card would be the copy that lags —
/// every change made to the live one would have to be remembered twice.
///
/// Rows describe *measurements*, not verdicts. A row's tint comes from
/// whether the CLI's own diagnosis array named the relevant rule, and its
/// comparison chip is the CLI's `summary` rendered verbatim. Nothing here
/// compares a number to a threshold or writes a sentence about one.
struct RunReportView: View {
    let snapshot: RunSnapshot
    /// nil for a live run: a run has nothing to be compared against until
    /// it is in the store.
    var comparison: RunDetail.Comparison?
    /// The CLI's own bytes for this run, when the caller has them. `nil`
    /// for a snapshot decoded without them — the Copy control says so
    /// rather than silently vanishing.
    var rawJSON: String?
    /// Whether each diagnosis shows its rule id. Passed in rather than read
    /// from `Defaults` so the captions appear the instant the enclosing
    /// expert disclosure is opened, not on the next launch.
    var showRuleIDs: Bool = false

    /// For `coordinator.rulesCatalog` — the category-driven row health
    /// below, and the `RuleChip`s in the diagnosis captions.
    @Environment(NetdiagCoordinator.self) private var coordinator

    @State private var shareError: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
            copyRow
            diagnoses
        }
    }

    // MARK: - Copy report

    /// Copies the CLI's own redacted rendering, never a re-encode of this
    /// app's partial model — the same reason `RunResult` keeps `rawJSON`
    /// around at all.
    @ViewBuilder
    private var copyRow: some View {
        HStack(spacing: 8) {
            Button(didCopy ? "Copied" : "Copy report") {
                copyShareableReport()
            }
            .controlSize(.small)
            .disabled(didCopy || rawJSON == nil)
            Text("Plain text, with your network name, IP addresses and location masked.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let shareError {
                Text(shareError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func copyShareableReport() {
        guard let raw = rawJSON else {
            shareError = "This report came from an older netdiag and can't be shared."
            return
        }
        Task { @MainActor in
            do {
                let text = try await NetdiagRunner.share(rawJSON: raw)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                shareError = nil
                didCopy = true
                try? await Task.sleep(for: .seconds(2))
                didCopy = false
            } catch {
                shareError = "Couldn't build a shareable report."
            }
        }
    }

    // MARK: - Report card

    /// Columns: symbol · label (+ help hint) · this run's value · the
    /// network's median · a short verdict chip. The full CLI sentence that
    /// used to sit in the last column moved to that chip's `.help(...)` —
    /// see `verdictColumn` — so the numbers a user actually asked to see
    /// (the median) are always visible and the prose is on demand.
    private var card: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.symbolTint)
                        .frame(width: 18)
                    HStack(spacing: 4) {
                        Text(row.label)
                        if let key = row.glossaryKey { HelpHint(key: key) }
                    }
                    .frame(width: 156, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(row.measured ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                        // Safety net for any value long enough to
                        // tail-truncate at this column's fixed width (the
                        // Wi-Fi row's sudo-hint fallback is the current
                        // longest) — the full string is always one hover
                        // away instead of silently lost.
                        .help(row.value)
                    medianColumn(row)
                        .frame(width: 96, alignment: .leading)
                    Spacer(minLength: 4)
                    verdictColumn(row)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                Divider()
            }
        }
        .cardStyle()
    }

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let health: Health
        /// Which entry of the comparison to hang off this row, using
        /// helpers/history.py's own metric keys. A row summarising several
        /// numbers at once — the DNS row counts resolvers — has none, and
        /// gets no median or chip rather than either about one of them.
        let metricKey: String?
        /// `helpers/rules_catalog.py`'s `metrics[].key` for this row's
        /// `HelpHint` — a different key space from `metricKey` (that one
        /// names a history.py comparison metric; this one names a
        /// glossary term) even though most rows below happen to share the
        /// same word for both.
        let glossaryKey: String?
        /// Renders `comparison.metrics[metricKey].median` the same way
        /// this row already renders its own `value` — reused rather than
        /// re-derived so the two columns can never disagree about units.
        /// `nil` alongside a `nil` `metricKey`.
        let medianFormatter: ((Double) -> String)?
        /// Rows that state a *configuration* rather than grade a measured
        /// quality — VPN, NAT topology, IPv6 availability, Local network.
        /// "VPN: not active" is a fact, not an all-clear, and a green dot
        /// beside it reads as "your VPN is healthy", a claim nothing here
        /// made. These show a neutral mark unless a rule actually fired.
        var informational: Bool = false

        /// Did this run actually produce a number for the row? Derived from
        /// the rendered value rather than carried separately, so it cannot
        /// disagree with what the user reads in the next column.
        ///
        /// `n/a` counts as unmeasured alongside `not measured`: a link
        /// whose ping is being dropped by policy produced no reading, and
        /// the whole point of printing `n/a` instead of "100%" is to stop
        /// the row asserting one.
        var measured: Bool {
            !Self.absentPrefixes.contains { value.hasPrefix($0) }
        }

        /// Every way a value can say "this run established no number
        /// here". Kept as one list because `measured` gates the green dot,
        /// and a new phrasing that forgot to join it would silently put an
        /// all-clear back beside a blank.
        static let absentPrefixes = ["not measured", "not recorded", "n/a"]

        /// A green dot is a claim — "checked, and fine". `health` alone
        /// cannot make it, because it reports only whether a *rule* fired,
        /// and no rule fires about a check that never ran. That put a green
        /// dot beside "Under load: not measured", "Packet size (MTU): not
        /// measured" and "Clock: not measured" in the same report whose
        /// headline was a critical, which is the strongest possible way to
        /// tell a user the app is not paying attention.
        ///
        /// Only the all-clear is downgraded. A row that is unmeasured
        /// *because* something failed — the Internet row under N1, say —
        /// keeps its warning or critical symbol: there the absence of a
        /// number is the finding.
        ///
        /// Two more cases join "never ran" in failing to earn the dot: a
        /// reading the CLI told us not to trust (`n/a` under TCP-1 /
        /// ICMP-1, where the loss figure describes the probe rather than
        /// the link), and a row that states a configuration rather than
        /// grading a quality (`informational`).
        private var claimsAllClear: Bool {
            health == .healthy && measured && !informational
        }

        var symbol: String {
            claimsAllClear ? health.symbol : (health == .healthy ? "minus.circle" : health.symbol)
        }

        var symbolTint: Color {
            claimsAllClear ? health.tint : (health == .healthy ? .secondary : health.tint)
        }
    }

    /// Row → category mapping. One row per measurement family the catalog
    /// knows about, so that **every** category has somewhere to land.
    ///
    ///   | Row                  | categories      |
    ///   |----------------------|-----------------|
    ///   | Router               | router          |
    ///   | Internet             | internet        |
    ///   | Packet loss          | internet        |
    ///   | Name lookups (DNS)   | dns             |
    ///   | Wi-Fi signal         | wifi            |
    ///   | Under load           | load            |
    ///   | Speed                | speed, baseline |
    ///   | Packet size (MTU)    | mtu             |
    ///   | IPv6                 | ipv6            |
    ///   | VPN                  | vpn             |
    ///   | NAT topology         | topology        |
    ///   | Local network        | lan, dhcp       |
    ///   | Clock                | clock           |
    ///
    /// Three things this table fixes, all of them the same underlying
    /// mistake — treating a category as a loose topic tag rather than as
    /// the name of the row whose number the rule is judging:
    ///
    /// 1. **`router` no longer bleeds into Internet.** It did, to catch
    ///    `N1`. But it also caught `G3`, whose own sentence reads "not to
    ///    the wider internet, so your internet service itself looks fine
    ///    from here" — printed directly under an amber Internet row.
    /// 2. **`dhcp` no longer tints DNS.** `DH-1` is "your address lease
    ///    expires soon"; it was turning "6 of 6 resolvers OK" amber.
    /// 3. **`ipv6`, `topology`, `vpn` and `speed` tint something.** They
    ///    previously matched no row at all, so a run firing `V6-1`,
    ///    `NAT-1` or `WAN-1` showed an entirely green card above its own
    ///    amber findings.
    ///
    /// `G1` is handled by the catalog rather than here: it is `router`
    /// with `also: wifi`, so it tints the row carrying the loss figure
    /// *and* the row naming the cause. See `helpers/rules_catalog.py`.
    ///
    /// The invariant — every category maps to at least one row — is
    /// asserted at runtime by `--verify` (see `VerifyMode.swift`), because
    /// the failure mode when it lapses is silent: a new rule family simply
    /// colours nothing, and the card looks healthy.
    static let rowCategories: [String: Set<String>] = [
        "Router": ["router"],
        "Internet": ["internet"],
        "Packet loss": ["internet"],
        "Name lookups (DNS)": ["dns"],
        "Wi-Fi signal": ["wifi"],
        "Under load": ["load"],
        "Speed": ["speed", "baseline"],
        "Packet size (MTU)": ["mtu"],
        "IPv6": ["ipv6"],
        "VPN": ["vpn"],
        "NAT topology": ["topology"],
        "Local network": ["lan", "dhcp"],
        "Clock": ["clock"],
    ]

    private var rows: [Row] {
        let s = snapshot
        let catalog = coordinator.rulesCatalog.catalog

        /// The exact behavior every row used before the catalog existed,
        /// and the only behavior a CLI too old to have `--rules-catalog`
        /// ever produces.
        func legacyHealth(_ rules: [String]) -> Health {
            let hits = s.diagnosis.filter { d in d.rule.map(rules.contains) ?? false }
            if hits.contains(where: { $0.severity == "critical" }) { return .critical }
            if hits.contains(where: { $0.severity == "warn" }) { return .warning }
            return .healthy
        }

        /// Every diagnosis entry whose rule belongs to one of
        /// `categories`, tinted by that *entry's own* severity — never the
        /// catalog's rule-general one (see `RulesCatalog.Rule`'s header).
        ///
        /// Membership is `Rule.categories`, not `Rule.category`: a rule
        /// may name a second family it is also about, and reading the
        /// primary alone is what left the Router row green beside "35%
        /// loss" while `G1` reddened a Wi-Fi row with no number in it.
        ///
        /// `nil` when no catalog is loaded, so `health(_:_:)` below knows
        /// to fall back rather than mistake "loaded, zero hits" for "not
        /// loaded at all".
        func categoryHealth(_ categories: Set<String>) -> Health? {
            guard let catalog else { return nil }
            let hits = s.diagnosis.filter { d in
                guard let rule = d.rule, let entry = catalog[rule] else { return false }
                return !categories.isDisjoint(with: entry.categories)
            }
            if hits.contains(where: { $0.severity == "critical" }) { return .critical }
            if hits.contains(where: { $0.severity == "warn" }) { return .warning }
            return .healthy
        }

        func health(_ legacyRules: [String], _ label: String) -> Health {
            let categories = Self.rowCategories[label] ?? []
            return categoryHealth(categories) ?? legacyHealth(legacyRules)
        }

        /// Did any rule in this row's families fire at all, at any
        /// severity? Drives whether a row that is normally hidden (NAT
        /// topology, Local network) appears. Without it a rule could fire
        /// with its row absent, which is the same silence this whole
        /// table exists to end — just one level up.
        func fired(_ label: String) -> Bool {
            guard let catalog else { return false }
            let categories = Self.rowCategories[label] ?? []
            return s.diagnosis.contains { d in
                guard let rule = d.rule, let entry = catalog[rule] else { return false }
                return !categories.isDisjoint(with: entry.categories)
            }
        }

        var out: [Row] = []
        out.append(Row(label: "Router",
                       value: gatewayValue,
                       health: health(["G1", "G2", "G3", "DI-1"], "Router"),
                       metricKey: "gateway_rtt_ms",
                       glossaryKey: "router",
                       medianFormatter: { String(format: "%.1f ms", $0) }))
        out.append(Row(label: "Internet",
                       value: internetValue,
                       health: health(["L1", "L2", "P1", "P2", "N1", "N1b"], "Internet"),
                       metricKey: "inet_rtt_ms",
                       glossaryKey: "internet",
                       medianFormatter: { String(format: "%.0f ms", $0) }))
        // Its own row rather than a suffix on Internet, for the reason
        // lib/headline.sh gives for the same split: loss and latency are
        // different faults with different fixes, and loss is the one users
        // experience as "the internet is down".
        out.append(Row(label: "Packet loss",
                       value: packetLossValue,
                       health: health(["L1", "L2"], "Packet loss"),
                       metricKey: "inet_loss_pct",
                       glossaryKey: "packet_loss",
                       medianFormatter: { String(format: "%.1f%%", $0) }))
        out.append(Row(label: "Name lookups (DNS)",
                       value: s.dns.isEmpty ? absentReason
                            : "\(s.dns.filter(\.ok).count) of \(s.dns.count) resolvers OK",
                       health: health(["D1", "D2", "D3", "D4"], "Name lookups (DNS)"),
                       metricKey: nil,
                       glossaryKey: "dns",
                       medianFormatter: nil))
        // Unconditional on `wifi` alone, matching every other row's
        // absent-value fallback — only the presence of `rssi` inside it is
        // optional, not the row. A wired run has no `wifi` object at all
        // and correctly shows nothing; a Wi-Fi run without `sudo` says why
        // instead of the row just not being there.
        if let wifi = s.wifi {
            // "not recorded", not "not measured": on Home this row sits a
            // few inches under a live Wi-Fi reading taken from macOS
            // directly, so "not measured" had the card flatly denying a
            // number the same screen was already showing. The two answer
            // different questions — what this check wrote down, versus
            // what the radio says right now — and only the first one needs
            // sudo. Saying "recorded" scopes the claim to the run.
            out.append(Row(label: "Wi-Fi signal",
                           value: wifi.rssi.map { "\($0) dBm" } ?? "not recorded (needs sudo)",
                           health: health(["W1", "W2", "WS-1", "WD-1"], "Wi-Fi signal"),
                           metricKey: "wifi_rssi_dbm",
                           glossaryKey: "wifi_signal",
                           medianFormatter: { "\(Int($0.rounded())) dBm" }))
        }
        out.append(Row(label: "Under load",
                       value: bufferbloatValue,
                       health: health(["B1", "B2"], "Under load"),
                       metricKey: "bufferbloat_gw_ms",
                       glossaryKey: "bufferbloat",
                       medianFormatter: { String(format: "+%.0f ms", $0) }))
        out.append(Row(label: "Speed",
                       value: speedValue,
                       health: health(["BL-1", "SP-1"], "Speed"),
                       metricKey: "speed_down_mbps",
                       glossaryKey: "speed",
                       medianFormatter: { String(format: "%.0f Mbps down", $0) }))
        out.append(Row(label: "Packet size (MTU)",
                       value: s.mtu.effective.map { "\($0) bytes" } ?? absentReason,
                       health: health(["M1"], "Packet size (MTU)"),
                       metricKey: "mtu_effective",
                       glossaryKey: "mtu",
                       medianFormatter: { "\(Int($0.rounded())) bytes" }))
        out.append(Row(label: "IPv6",
                       value: ipv6Value,
                       health: health(["V6-1", "V6-2"], "IPv6"),
                       metricKey: nil,
                       glossaryKey: nil,
                       medianFormatter: nil,
                           informational: true))
        out.append(Row(label: "VPN",
                       value: s.vpn.active ? (s.vpn.name ?? s.vpn.type ?? "active") : "not active",
                       health: health(["VPN-1", "VPN-2"], "VPN"),
                       metricKey: nil,
                       glossaryKey: nil,
                       medianFormatter: nil,
                           informational: true))
        // Hidden on an ordinary single-router network, which is almost
        // every network — but never hidden while a rule about it is
        // firing, or the finding below would have no row to sit against.
        if s.wan.doubleNat.detected || s.wan.doubleNat.ispTransitCount > 1
            || s.wan.upnp.state == "enabled" || fired("NAT topology") {
            out.append(Row(label: "NAT topology",
                           value: natTopologyValue,
                           health: health(["NAT-1", "WAN-1"], "NAT topology"),
                           metricKey: nil,
                           glossaryKey: nil,
                           medianFormatter: nil,
                           informational: true))
        }
        // Same conditional shape, same reason.
        if !s.duplicateIPs.isEmpty || fired("Local network") {
            out.append(Row(label: "Local network",
                           value: localNetworkValue,
                           health: health(["DI-1", "DI-2", "ETH-1", "ETH-2", "DH-1", "DH-3"],
                                          "Local network"),
                           metricKey: nil,
                           glossaryKey: nil,
                           medianFormatter: nil,
                           informational: true))
        }
        out.append(Row(label: "Clock",
                       value: s.ntp.driftSeconds.map { String(format: "%+.2f s off", $0) } ?? absentReason,
                       health: health(["NT-1"], "Clock"),
                       metricKey: "ntp_drift_s",
                       glossaryKey: "clock",
                       medianFormatter: { String(format: "%+.2f s", $0) }))
        return out
    }

    // MARK: - Row values
    //
    // Each of these answers "what did this run actually establish about
    // this measurement?" — including, importantly, the cases where the
    // honest answer is that the number on the wire does not describe the
    // link. Every branch keys off something the CLI emitted (a rule id, a
    // run mode, a flag); none of them compares a number to a threshold.

    /// Which rules this run fired, for the render-time questions below.
    private var firedRules: Set<String> {
        Set(snapshot.diagnosis.compactMap(\.rule))
    }

    /// `TCP-1`: real connections cross the gateway fine and only ping is
    /// being dropped, so the gateway loss figure describes the probe, not
    /// the link. Printing it as a measurement put a red row directly above
    /// the CLI's own "don't worry about the ping numbers above".
    private var gatewayPingBlocked: Bool { firedRules.contains("TCP-1") }

    /// `ICMP-1`: the same statement for the two public targets.
    private var internetPingBlocked: Bool { firedRules.contains("ICMP-1") }

    /// Why a value is absent, in the CLI's own terms. "Not measured" reads
    /// as *we tried and failed*; on a quick check the truth is *we skipped
    /// it because you asked for the fast answer*, and five of this card's
    /// rows are in that state on the depth both primary buttons run.
    ///
    /// Deliberately does not name *which* checks a mode skips — that table
    /// lives in `bin/netdiag` and would rot here. It states only the two
    /// things this side genuinely knows: the value is absent, and this run
    /// was a check of that depth.
    private var absentReason: String {
        switch snapshot.runMode {
        case "quick":
            return "not measured (quick check)"
        case .some(let mode) where mode.hasSuffix("-only"):
            let badge = HistoryDocument.Run.modeBadge(for: mode) ?? mode
            return "not measured (\(badge))"
        default:
            return "not measured"
        }
    }

    private var gatewayValue: String {
        if gatewayPingBlocked { return "n/a — ping blocked" }
        return format(snapshot.gateway.rttAvgMs, "%.1f ms", loss: snapshot.gateway.lossPct)
    }

    private var internetValue: String {
        if internetPingBlocked { return "n/a — ping blocked" }
        // On an IPv6-only network the v4 probe cannot succeed by
        // construction — there is no IPv4 here to probe over — so its
        // 100% is a fact about the probe, not about the connection. V6-3
        // says so in prose; this stops the row contradicting it.
        if snapshot.ipv6.only { return "n/a — carried over IPv6" }
        return format(snapshot.internetLatency.rttAvgMs, "%.0f ms",
                      loss: snapshot.internetLatency.lossPct)
    }

    private var packetLossValue: String {
        if internetPingBlocked { return "n/a — ping blocked" }
        if snapshot.ipv6.only { return "n/a — no IPv4 on this network" }
        let primary = snapshot.internetLatency.lossPct
        let alt = snapshot.internetLatency.lossPctAlt
        guard primary != nil || alt != nil else { return absentReason }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "?" }
        let text = "\(pct(primary)) / \(pct(alt)) to two targets"
        // "clean" is not a verdict about the network, it is the reading:
        // both probes came back whole. Mirrors lib/headline.sh's own
        // suffix on the same row.
        if primary == 0, alt == 0 { return "\(text) · clean" }
        return text
    }

    /// Both legs, not just the gateway's. The row's tint already comes
    /// from B1 *or* B2, so showing only `gwGrade` put a red dot beside the
    /// words "grade A" whenever the ISP leg was the bad one.
    private var bufferbloatValue: String {
        let bb = snapshot.bufferbloat
        guard let gw = bb.gwGrade else { return absentReason }
        let gwPart = bb.gwDeltaMs.map { String(format: "%@ (+%.0f ms)", gw, $0) } ?? gw
        guard let inet = bb.inetGrade else { return "grade \(gwPart)" }
        let inetPart = bb.inetDeltaMs.map { String(format: "%@ (+%.0f ms)", inet, $0) } ?? inet
        return "router \(gwPart) · ISP \(inetPart)"
    }

    private var speedValue: String {
        guard let speed = snapshot.speedtest else { return absentReason }
        let parts = [speed.downMbps.map { String(format: "%.0f Mbps down", $0) },
                     speed.upMbps.map { String(format: "%.0f up", $0) }].compactMap { $0 }
        return parts.isEmpty ? absentReason : parts.joined(separator: " · ")
    }

    /// The CLI's own three-way split (`lib/headline.sh`): working,
    /// available but broken, or genuinely absent — plus the fourth case
    /// V6-3 added, where IPv6 is the only protocol here and that is fine.
    private var ipv6Value: String {
        let v6 = snapshot.ipv6
        if v6.only { return v6.clat ? "only protocol here · translating" : "only protocol here" }
        guard v6.available else { return "not available (IPv4-only network)" }
        return v6.aaaaOk && v6.tcpV6Ok ? "working" : "available but not working"
    }

    private var natTopologyValue: String {
        let nat = snapshot.wan.doubleNat
        if nat.detected {
            return "double-NAT · \(nat.homeCount) routers chained"
        }
        if nat.ispTransitCount > 1 {
            return "ISP transit via private addresses (normal)"
        }
        if snapshot.wan.upnp.state == "enabled" { return "UPnP enabled" }
        return "single router"
    }

    private var localNetworkValue: String {
        if !snapshot.duplicateIPs.isEmpty {
            let n = snapshot.duplicateIPs.count
            return "duplicate address\(n == 1 ? "" : "es") on the LAN"
        }
        // The row is only built when something here fired, so reaching
        // this line means a lan/dhcp rule is describing it. Point at that
        // rather than inventing a second summary of the same fact.
        return "see the finding below"
    }

    /// "not measured" rather than a zero. The CLI's schema draws that line
    /// deliberately — treating an unmeasured value as zero is what produced
    /// false diagnoses in earlier versions — and the UI has to hold it too.
    ///
    /// Loss is read before the RTT is given up on, because total loss has no
    /// average RTT *by definition*: every packet that would have contributed
    /// one was dropped. Checking `value` first printed "not measured" on the
    /// exact runs where loss was the whole story — a red ✗ beside "not
    /// measured", directly under a headline quoting "100.0% of the packets".
    private func format(_ value: Double?, _ fmt: String, loss: Double?) -> String {
        guard let value else {
            guard let loss, loss > 0 else { return absentReason }
            return String(format: "%.0f%% loss, no reply", loss)
        }
        var text = String(format: fmt, value)
        if let loss, loss > 0 { text += String(format: " · %.0f%% loss", loss) }
        return text
    }

    // MARK: - Comparison
    //
    // Two columns instead of one long sentence: the network's median is
    // always visible (the number the user asked to see), and the verdict
    // is a short chip carrying the CLI's own `verdict` token — never a
    // Swift-authored word — with the full CLI sentence a `.help(...)`
    // hover away. Both degrade to "—" rather than an empty gap: no
    // comparison yet (a live run), a row with no `metricKey` (DNS), or a
    // verdict this build treats as "nothing to show" all render the same
    // placeholder, so the column never looks broken.

    private static let noValuePlaceholder = "—"

    @ViewBuilder
    private func medianColumn(_ row: Row) -> some View {
        if let key = row.metricKey, let median = comparison?.metrics[key]?.median,
           let format = row.medianFormatter {
            Text("median \(format(median))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(Self.noValuePlaceholder)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// The chip words: "Typical" / "Better" / "Worse" / "Best" / "Worst",
    /// straight from `comparison.metrics[key].verdict` — the machine token
    /// docs/JSON-SCHEMA.md documents, capitalised and nothing else. A
    /// verdict of `insufficientData` / `notMeasured` / `unknown`, or no
    /// comparison at all, shows the same "—" placeholder `medianColumn`
    /// does rather than a chip with nothing useful in it.
    @ViewBuilder
    private func verdictColumn(_ row: Row) -> some View {
        if let key = row.metricKey, let metric = comparison?.metrics[key],
           Self.chipVerdicts.contains(metric.verdict) {
            Text(metric.verdict.displayWord)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(metric.verdict.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(metric.verdict.tint.opacity(0.15), in: Capsule())
                // The full CLI sentence, on demand — exactly what this
                // column showed inline before this task.
                .help(metric.summary)
        } else {
            Text(Self.noValuePlaceholder)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private static let chipVerdicts: Set<RunDetail.Verdict> = [.typical, .better, .worse, .best, .worst]

    // MARK: - Diagnoses

    private var diagnoses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What we found").font(.headline)
            if snapshot.diagnosis.isEmpty {
                Label("Nothing obviously wrong — your network looks healthy.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(snapshot.diagnosis) { d in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: d.health.symbol)
                        .foregroundStyle(d.health.tint)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        // Verbatim. The CLI already writes this for a
                        // non-technical reader; rewording it here would be
                        // the app inventing a second opinion.
                        Text(d.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        if showRuleIDs, let rule = d.rule {
                            // Same expert-gating as before (`showRuleIDs`),
                            // same caption text — "rule" and "— see
                            // docs/DIAGNOSIS-RULES.md" — with the id itself
                            // now a `RuleChip`: tappable with a catalog
                            // loaded, the identical inert capsule this
                            // caption's bare `Text(rule)` used to be
                            // without one.
                            HStack(spacing: 4) {
                                Text("rule").font(.caption).foregroundStyle(.secondary)
                                RuleChip(ruleID: rule)
                                Text("— see docs/DIAGNOSIS-RULES.md")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension RunDetail.Verdict {
    /// Colour only, and deliberately not the diagnosis palette. "Worse than
    /// usual for this network" is a statement about a distribution, not a
    /// fault — a run can sit in the slow tail with nothing wrong with it —
    /// so it stops at orange and never reaches the red that means the CLI
    /// found a problem.
    var tint: Color {
        switch self {
        case .best, .better:   return .green
        case .worst, .worse:   return .orange
        case .typical:         return .secondary
        case .insufficientData, .notMeasured, .unknown: return .secondary
        }
    }

    /// The verdict chip's word: this case's own raw token, title-cased —
    /// never a synonym invented in Swift. Every case currently shown in a
    /// chip (`typical`/`better`/`worse`/`best`/`worst`) has no underscore
    /// to begin with; the replace is here so a future verdict this app
    /// doesn't special-case yet (see `RunReportView.chipVerdicts`) still
    /// reads as words instead of `snake_case` the day it's added to that
    /// set.
    var displayWord: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
