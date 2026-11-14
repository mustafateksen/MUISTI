import SwiftUI

/// The rule Muisti wrote from the user's words, before it is added.
struct SafetyRulePreview: View {
    let rule: SafetyRule

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("Muisti wrote", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            Text(rule.summary)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label(rule.triggerText, systemImage: rule.triggerSymbol)
                if !rule.watch.isEmpty {
                    Label(rule.watch.map(SafetyNames.display).joined(separator: ", "), systemImage: "eye")
                }
                Label(rule.severity.title, systemImage: rule.severity.symbol)
                    .foregroundStyle(rule.severity.tint)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .card(padding: Theme.Spacing.l)
    }
}
