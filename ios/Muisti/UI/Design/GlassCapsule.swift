import SwiftUI

/// Liquid Glass capsule on iOS 26+, a material capsule with a hairline before that.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}

extension View {
    func glassCapsule() -> some View {
        modifier(GlassCapsule())
    }
}
