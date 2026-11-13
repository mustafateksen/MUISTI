import SwiftUI

/// The standard card surface: secondary background, continuous corners, hairline border.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var padding: CGFloat = Theme.Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card, padding: CGFloat = Theme.Spacing.l) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }
}
