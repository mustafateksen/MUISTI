import SwiftUI

/// Earlier questions in this session (newest first, excluding the one on screen).
struct AskHistoryList: View {
    let items: [AskResult]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Önceki sorular")
                .font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    Image(systemName: item.label == .seen ? "checkmark.seal.fill" : "questionmark.circle")
                        .foregroundStyle(item.label == .seen ? .green : .orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(item.question)
                            .font(.subheadline.bold())
                        Text(item.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .card(radius: Theme.Radius.inner, padding: Theme.Spacing.m)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
