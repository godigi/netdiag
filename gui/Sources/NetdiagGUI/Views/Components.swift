import SwiftUI

/// Small views shared by more than one screen. `RuleChip` is the first
/// tenant; anything else that stops being one view's private detail moves
/// here rather than getting copy-pasted a second time.

/// A rule id, rendered as a capsule. The one place in this app a rule id
/// becomes a piece of UI — `RunListView` and `RunReportView` both used to
/// hand-roll this capsule themselves, which is exactly the kind of drift
/// this component closes off, the same way `Theme.cardStyle()` closed off
/// eight hand-rolled cards.
///
/// Two renderings, chosen by whether `RulesCatalogStore` has anything to
/// say about `ruleID`:
///
/// - **With a catalog entry:** tappable. A tap opens a popover with the
///   rule's title, a meta line naming its id and the catalog's own
///   (rule-general, not this-incident) severity, the catalog's blurb
///   verbatim, and a link into `docs/DIAGNOSIS-RULES.md` on GitHub for the
///   full trigger condition.
/// - **Without one** — no catalog loaded yet, an old CLI, or an id the
///   catalog doesn't recognise — an inert capsule with the bare id. This
///   is deliberately byte-for-byte what `RunListView` always rendered
///   before this component existed: nothing about the chip's appearance
///   changes for a user whose CLI predates `--rules-catalog`.
struct RuleChip: View {
    let ruleID: String
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var showPopover = false

    var body: some View {
        if let rule = coordinator.rulesCatalog.catalog?[ruleID] {
            Button { showPopover = true } label: { capsule }
                .buttonStyle(.plain)
                .help("What rule \(ruleID) means")
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    RuleChipPopover(rule: rule)
                }
        } else {
            capsule
        }
    }

    /// The exact styling `RunListView`'s chip used before this file
    /// existed — see that view's git history for the literal it was lifted
    /// from.
    private var capsule: some View {
        Text(ruleID)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
    }
}

/// The popover a tappable `RuleChip` opens. Every string here is either the
/// CLI's own catalog prose, rendered verbatim, or presentational scaffolding
/// around it ("Rule", "·", the link label) — nothing composes an opinion
/// about the rule.
private struct RuleChipPopover: View {
    let rule: RulesCatalog.Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rule.title ?? rule.id).font(.headline)
            Text(metaLine).font(.caption).foregroundStyle(.secondary)
            if let blurb = rule.blurb, !blurb.isEmpty {
                Text(blurb)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let url = docURL {
                Link("More in the Diagnosis guide", destination: url)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    /// "Rule G3 · warning · judged by the CLI, not the app" — the
    /// mockup's own wording (nimbalyst-local/mockups/netdiag-activity.
    /// mockup.html), restated here rather than copied as a literal because
    /// the id and severity are this rule's, not the mockup's example.
    /// `severity` is the catalog's rule-general answer, not this
    /// incident's — see `RulesCatalog.Rule`'s header — which is exactly
    /// why the line says "judged by the CLI, not the app": the popover is
    /// reference material about the rule, not a verdict about this run.
    private var metaLine: String {
        "Rule \(rule.id) · \(rule.severity ?? "info") · judged by the CLI, not the app"
    }

    /// `rule.doc` is a repo-relative anchor into `docs/DIAGNOSIS-RULES.md`
    /// (docs/JSON-SCHEMA.md: "a GitHub-style anchor"); this is that same
    /// string turned into the GitHub URL a `Link` can actually open.
    /// `godigi/netdiag` and the `main` branch match every other hardcoded
    /// reference to this repo in the app (`BinaryLocator.missingBinaryMessage`).
    private var docURL: URL? {
        guard let doc = rule.doc, !doc.isEmpty else { return nil }
        return URL(string: "https://github.com/godigi/netdiag/blob/main/docs/\(doc)")
    }
}

/// A small "what does this mean?" affordance next to a jargon term —
/// `RunReportView`'s answer to "When I see 'packets', 'size', and 'MTU', I
/// have no idea what they mean." Looks `key` up in
/// `RulesCatalogStore`'s `metrics` glossary (schema `2`,
/// `helpers/rules_catalog.py`) and shows the CLI's own `help` sentence —
/// never a Swift-authored explanation, the same discipline `RuleChip`
/// applies to a rule's blurb.
///
/// Renders nothing when the glossary hasn't loaded yet or doesn't
/// recognise `key` (an old CLI, or a term this build asks about that a
/// future catalog renamed) — an absent hint is a smaller gap than a
/// button that opens on an empty popover.
struct HelpHint: View {
    let key: String
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var showPopover = false

    var body: some View {
        if let metric = coordinator.rulesCatalog.catalog?.metric(key), let help = metric.help, !help.isEmpty {
            Button { showPopover = true } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(help)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.label ?? key).font(.headline)
                    Text(help)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
            }
        }
    }
}
