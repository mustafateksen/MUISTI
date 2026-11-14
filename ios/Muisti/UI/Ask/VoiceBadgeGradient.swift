import SwiftUI

/// The orb's resting colours as a fill, for small voice buttons and the assistant avatar.
struct VoiceBadgeGradient: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        let c = VoicePalette.colors(for: .idle)
        return LinearGradient(
            colors: [VoicePalette.color(c[0]), VoicePalette.color(c[2]), VoicePalette.color(c[1])],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}
