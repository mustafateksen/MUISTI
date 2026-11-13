import SwiftUI

/// A soft wash of the assistant's current colours behind the top of the Ask screen.
struct AskBackdrop: View {
    let phase: VoiceAssistant.Phase

    var body: some View {
        let colors = VoicePalette.colors(for: phase)
        EllipticalGradient(
            colors: [
                VoicePalette.color(colors[0], opacity: 0.22),
                VoicePalette.color(colors[2], opacity: 0.08),
                .clear,
            ],
            center: UnitPoint(x: 0.5, y: 0.2),
            startRadiusFraction: 0,
            endRadiusFraction: 0.75
        )
        .frame(height: 520)
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.8), value: phase)
        .accessibilityHidden(true)
    }
}
