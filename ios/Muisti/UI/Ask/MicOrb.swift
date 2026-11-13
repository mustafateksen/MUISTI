import SwiftUI

/// The big push-to-talk button. Rings ripple outward while listening.
struct MicOrb: View {
    let phase: VoiceAssistant.Phase
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isListening: Bool { phase == .listening }
    private var isThinking: Bool { phase == .thinking }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening, !reduceMotion {
                    ForEach(0..<2, id: \.self) { ring in
                        Circle()
                            .stroke(Color.red.opacity(0.5), lineWidth: 2)
                            .phaseAnimator([false, true]) { circle, expanded in
                                circle
                                    .scaleEffect(expanded ? 1.6 : 1)
                                    .opacity(expanded ? 0 : 1)
                            } animation: { expanded in
                                expanded ? .easeOut(duration: 1.8).delay(Double(ring) * 0.6) : .linear(duration: 0.01)
                            }
                    }
                }
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isListening ? [.red, .pink] : [.accentColor, .accentColor.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: (isListening ? Color.red : .accentColor).opacity(0.35), radius: 18, y: 8)
                Image(systemName: icon)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: isListening || phase == .speaking)
                    .symbolEffect(.pulse, isActive: isThinking)
            }
            .frame(width: 140, height: 140)
            .scaleEffect(isListening && !reduceMotion ? 1.05 : 1)
            .animation(.spring(duration: 0.4, bounce: 0.35), value: isListening)
        }
        .buttonStyle(.plain)
        .disabled(isThinking)
        .accessibilityLabel(isListening ? "Dinlemeyi bitir" : "Sesli soru sor")
        .accessibilityInputLabels(["Sor", "Dinle", "Mikrofon"])
        .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
    }

    private var icon: String {
        switch phase {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        default: return "mic.fill"
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        MicOrb(phase: .idle) {}
        MicOrb(phase: .listening) {}
    }
}
