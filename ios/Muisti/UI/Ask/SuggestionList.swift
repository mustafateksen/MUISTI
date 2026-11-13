import SwiftUI

/// Example questions; tapping one asks it.
struct SuggestionList: View {
    let onSelect: (String) -> Void

    static let suggestions: [(text: String, icon: String)] = [
        ("Geçtiğim sokaktaki dişçinin numarası neydi?", "phone"),
        ("Az önce gördüğüm eczane kaçta kapanıyor?", "clock"),
        ("Bugün hangi kafelerin önünden geçtim?", "cup.and.saucer"),
        ("Son gördüğüm tabelada ne yazıyordu?", "signpost.right"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Örnek sorular")
                .font(.headline)
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(Self.suggestions, id: \.text) { suggestion in
                    Button {
                        onSelect(suggestion.text)
                    } label: {
                        Label(suggestion.text, systemImage: suggestion.icon)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.s)
                            .frame(minHeight: 44)
                            .background(.background.secondary, in: Capsule())
                            .overlay { Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
