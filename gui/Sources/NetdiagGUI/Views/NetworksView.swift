import SwiftUI

/// One row per network group, with the two affordances that make the
/// grouping readable while macOS hides the SSID: **rename** and **merge**.
///
/// Neither is a nicety. Without Location Services every Wi-Fi network on
/// this machine is called "WiFi (SSID hidden by macOS)", so a rename is the
/// only way to tell home from the office. And helpers/history.py
/// deliberately refuses to guess when its bridge heuristic is ambiguous —
/// leaving two groups apart rather than merging them wrongly — so a manual
/// merge is the honest completion of that refusal, not a workaround for it.
struct NetworksView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var editingID: String?
    @State private var draftName = ""
    @State private var mergeSource: HistoryDocument.Network?

    private var store: HistoryStore { coordinator.history }

    var body: some View {
        // The stack lives inside the tab rather than around it, so browsing
        // into a network's history leaves the tab bar — and whatever Spec 2
        // decides about the window's overall shape — untouched.
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.mergedNetworks.isEmpty {
                        Text("No networks recorded yet. Run a check to start building history.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(store.mergedNetworks) { net in
                        row(net)
                    }
                }
                .padding(16)
            }
            .navigationDestination(for: NetworkRoute.self) { route in
                RunListView(networkID: route.networkID)
            }
        }
        .task { if store.document.networks.isEmpty { await store.load() } }
        .sheet(item: $mergeSource) { source in
            MergeSheet(source: source) { destination in
                store.merge(source.id, into: destination)
                mergeSource = nil
            } onCancel: {
                mergeSource = nil
            }
            .environment(coordinator)
        }
    }

    private func row(_ net: HistoryDocument.Network) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if editingID == net.id {
                    TextField("Network name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { commitRename(net) }
                    Button("Save") { commitRename(net) }
                    Button("Cancel") { editingID = nil }
                } else {
                    Text(store.displayName(for: net.id))
                        .font(.headline)
                    if isCurrent(net) {
                        Text("connected")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                    }
                    if net.synthesized {
                        // The UI stays honest about what it inferred.
                        // "synthesized" means the grouping was backfilled
                        // from records that predate network identity, or
                        // bridged/merged rather than recorded.
                        Text("inferred")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.18), in: Capsule())
                            .help("Grouped by inference — these runs predate network identity, or were bridged by matching gateway and ISP.")
                    }
                    Spacer()
                    // The card has said "1,915 checks" since the tab
                    // existed; this is the affordance that makes the number
                    // lead somewhere.
                    NavigationLink(value: NetworkRoute(networkID: net.id)) {
                        Text("Browse checks")
                    }
                    .buttonStyle(.link)
                    Button("Rename") {
                        editingID = net.id
                        draftName = store.displayName(for: net.id)
                    }
                    .buttonStyle(.link)
                    Button("Merge…") { mergeSource = net }
                        .buttonStyle(.link)
                    if store.manualMerges.values.contains(net.id) {
                        Button("Unmerge") { unmergeInto(net) }.buttonStyle(.link)
                    }
                }
            }

            HStack(spacing: 20) {
                stat("Checks", "\(net.runCount)")
                stat("Problems", "\(net.incidentCount)",
                     detail: net.runCount > 0
                        ? String(format: "%.0f%% of checks", net.incidentRate * 100) : nil)
                stat("Median router RTT", medianRTT(net))
                stat("Seen", dateRange(net))
            }
            .font(.caption)

            if !net.gateways.isEmpty || !net.isps.isEmpty {
                Text([net.gateways.joined(separator: ", "),
                      net.isps.joined(separator: ", ")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if !net.bridgedFrom.isEmpty {
                Text("includes: \(net.bridgedFrom.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    /// Median rather than mean: one 4,000 ms outlier from a moment the
    /// radio was reassociating would drag a mean somewhere no reading ever
    /// was, and the number is there to characterise the typical case.
    private func medianRTT(_ net: HistoryDocument.Network) -> String {
        let values = store.runs(networkID: net.id, window: .all)
            .compactMap { $0.metrics["gateway_rtt_ms"] }
            .sorted()
        guard !values.isEmpty else { return "no data" }
        let mid = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2 : values[mid]
        return String(format: "%.1f ms", median)
    }

    private func dateRange(_ net: HistoryDocument.Network) -> String {
        guard let first = net.firstSeenDate, let last = net.lastSeenDate else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yy"
        return first == last ? f.string(from: first)
            : "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private func isCurrent(_ net: HistoryDocument.Network) -> Bool {
        guard let id = coordinator.monitor.latest?.network.id else { return false }
        return store.canonicalID(id) == net.id
    }

    private func commitRename(_ net: HistoryDocument.Network) {
        store.rename(net.id, to: draftName)
        editingID = nil
    }

    private func unmergeInto(_ net: HistoryDocument.Network) {
        for (source, destination) in store.manualMerges where destination == net.id {
            store.unmerge(source)
        }
    }
}

/// Pick the group to merge into. Deliberately a deliberate action with a
/// visible list — the automatic heuristic already took every case it could
/// decide, so anything reaching this sheet is a judgement only the user can
/// make.
struct MergeSheet: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    let source: HistoryDocument.Network
    let onMerge: (String) -> Void
    let onCancel: () -> Void
    @State private var destination: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \"\(coordinator.history.displayName(for: source.id))\"")
                .font(.headline)
            Text("Its \(source.runCount) check(s) will be shown as part of the network you pick. This only changes how history is grouped in this app — nothing is deleted, and you can undo it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $destination) {
                ForEach(coordinator.history.mergedNetworks.filter { $0.id != source.id }) { net in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.history.displayName(for: net.id))
                        Text("\(net.runCount) checks · \(net.gateways.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(net.id)
                }
            }
            .frame(height: 200)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Merge") { if let destination { onMerge(destination) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
