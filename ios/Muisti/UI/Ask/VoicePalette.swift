import SwiftUI

/// The orb's three colours per assistant phase (deep, bright, accent), all taken from `Palette`,
/// as RGB so the orb can blend between phases frame by frame.
enum VoicePalette {
    typealias RGB = Palette.RGB

    static func colors(for phase: VoiceAssistant.Phase) -> [RGB] {
        switch phase {
        case .idle: [Palette.brand, Palette.sky, Palette.violet]
        case .listening: [Palette.brand * 0.9, Palette.sky, Palette.violet]
        case .thinking: [Palette.brand, Palette.orchid, Palette.violet]
        case .speaking: [Palette.brand, Palette.mint, Palette.sky]
        case .failed: [Palette.rose * 0.9, Palette.amber, Palette.rose]
        }
    }

    static func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Palette.color(rgb, opacity: opacity)
    }
}
