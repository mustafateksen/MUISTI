import SwiftUI

/// Muisti is waiting for a yes/no: a new rule, deleting one, or "did you take it?".
struct SafetyPendingRow: View {
    let pending: SafetyPending
    let frameURL: URL?
    let answer: (Bool) -> Void

    private var title: String {
        switch pending {
        case .rule: String(localized: "Add this rule?")
        case .deleteRule: String(localized: "Delete this rule?")
        case .action: String(localized: "Did this happen?")
        }
    }

    private var detail: String {
        switch pending {
        case .rule(let rule), .deleteRule(let rule): rule.summary
        case .action(let object, let action, _, let at):
            "\(SafetyNames.display(object)): \(action) · \(at.formatted(date: .omitted, time: .shortened))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                SafetyThumbnail(url: frameURL, title: detail, symbol: "questionmark.bubble.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: Theme.Spacing.s) {
                Button { answer(true) } label: {
                    Text("Yes").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                Button { answer(false) } label: {
                    Text("No").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.semibold))
        }
    }
}
