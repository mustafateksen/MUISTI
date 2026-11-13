import SwiftUI

/// A few quiet example questions; tapping one asks it.
struct SuggestionList: View {
    let onSelect: (String) -> Void

    static let suggestions = [
        "Dişçinin numarası neydi?",
        "Eczane kaçta kapanıyor?",
        "Son tabelada ne yazıyordu?",
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
        .accessibilityLabel("Örnek sorular")
    }
}
