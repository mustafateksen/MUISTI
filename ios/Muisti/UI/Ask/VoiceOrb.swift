import SwiftUI

/// The push-to-talk control: the visualizer, with a small symbol in the middle. Tap to ask,
/// tap again to stop listening.
struct VoiceOrb: View {
    let voice: VoiceAssistant
    let action: () -> Void

    private var phase: VoiceAssistant.Phase { voice.phase }

    var body: some View {
        Button(action: action) {
            VoiceVisualizer(phase: phase, levels: voice.levels)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: phase == .listening || phase == .speaking)
                        .symbolEffect(.pulse, isActive: phase == .thinking)
                }
                .contentShape(Circle().scale(0.6))
        }
        .buttonStyle(OrbPressStyle())
        .disabled(phase == .thinking)
        .accessibilityLabel(phase == .listening ? "Dinlemeyi bitir" : "Sesli soru sor")
        .accessibilityInputLabels(["Sor", "Dinle", "Mikrofon"])
        .sensoryFeedback(.impact(weight: .medium), trigger: phase == .listening)
    }

    private var icon: String {
        switch phase {
        case .listening: "waveform"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        case .failed: "mic.slash.fill"
        case .idle: "mic.fill"
        }
    }
}

/// Gentle squeeze while pressed.
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}
