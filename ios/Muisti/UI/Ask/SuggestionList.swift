import SwiftUI

/// A few quiet example questions; tapping one asks it.
struct SuggestionList: View {
    let onSelect: (String) -> Void

    static let suggestions = [
        "What was the dentist's number?",
        "When does the pharmacy close?",
        "What did the last sign say?",
    ]

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.xs, centered: true) {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button(suggestion) { onSelect(suggestion) }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(minHeight: 36)
                    .background(.fill.quaternary, in: Capsule())
                    .contentShape(.rect)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Example questions")
    }
}
