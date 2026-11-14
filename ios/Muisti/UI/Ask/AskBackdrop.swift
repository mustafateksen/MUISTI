import SwiftUI

/// Soft light behind the assistant: the current phase's colours glow from the top and bottom,
/// stronger in voice mode, barely there behind the chat so text stays easy to read.
struct AskBackdrop: View {
    let phase: VoiceAssistant.Phase
    let voiceMode: Bool

    var body: some View {
        let colors = VoicePalette.colors(for: phase)
        let strength = voiceMode ? 1.0 : 0.45
        ZStack {
            Rectangle().fill(.background)
            EllipticalGradient(
                colors: [VoicePalette.color(colors[0], opacity: 0.20 * strength), .clear],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )
            EllipticalGradient(
                colors: [VoicePalette.color(colors[2], opacity: 0.18 * strength), .clear],
                center: UnitPoint(x: 0.9, y: 0.35),
                startRadiusFraction: 0,
                endRadiusFraction: 0.6
            )
            EllipticalGradient(
                colors: [VoicePalette.color(colors[1], opacity: 0.16 * strength), .clear],
                center: UnitPoint(x: 0.4, y: 1.0),
                startRadiusFraction: 0,
                endRadiusFraction: 0.7
            )
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.9), value: phase)
        .animation(.smooth(duration: 0.6), value: voiceMode)
        .accessibilityHidden(true)
    }
}
