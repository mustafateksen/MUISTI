import SwiftUI

/// The user's rules in one card, or how to make one (by voice) when there are none.
struct SafetyRulesCard: View {
    let rules: [SafetyRule]
    let setEnabled: (SafetyRule, Bool) -> Void
    let delete: (SafetyRule) -> Void

    var body: some View {
        if rules.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Ask Muisti to watch something", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.tint)
                ForEach(["Warn me if I leave home with the stove on", "Remind me to take my blood pressure pill at 8", "Warn me about milk on product labels"], id: \.self) { example in
                    Text("“\(example)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .card(padding: Theme.Spacing.l)
        } else {
            VStack(spacing: 0) {
                ForEach(rules) { rule in
                    SafetyRuleRow(rule: rule, setEnabled: { setEnabled(rule, $0) }, delete: { delete(rule) })
                    if rule.id != rules.last?.id {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .card(padding: 0)
        }
    }
}
