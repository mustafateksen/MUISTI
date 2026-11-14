import SwiftUI

/// The orb's three colours per assistant phase (deep, bright, accent), all taken from `Palette`,
/// as RGB so the orb can blend between phases frame by frame.
enum VoicePalette {
    typealias RGB = Palette.RGB

    static func colors(for phase: VoiceAssistant.Phase) -> [RGB] {
        switch phase {
        case .idle: [Palette.brand, Palette.sky, Palette.blue]
        case .listening: [Palette.brand * 0.9, Palette.sky, Palette.blue]
        case .thinking: [Palette.ink * 1.6, Palette.blue, Palette.sky]
        case .speaking: [Palette.brand, Palette.sky, Palette.sky * 0.6 + 0.4]
        case .failed: [Palette.rose * 0.9, Palette.amber, Palette.rose]
        }
    }

    static func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Palette.color(rgb, opacity: opacity)
    }
}
