import SwiftUI

/// The voice orb (Metal shader), driven by a smoothed spectrum: it swells and ripples with the
/// microphone while listening and with the answer's own voice while speaking, a comet circles
/// it while thinking, and it breathes slowly at rest.
struct VoiceVisual: View {
    let phase: VoiceAssistant.Phase
    let levels: VoiceLevels
    @State private var state = VisualizerState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: phase == .idle ? 1 / 30 : nil, paused: reduceMotion)) { timeline in
            let _ = advance(to: timeline.date)
            orb
                .aspectRatio(1, contentMode: .fit)
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            if reduceMotion { state.snap(to: newPhase) }
        }
        .accessibilityHidden(true)
    }

    private var orb: some View {
        // Values captured here: `visualEffect` runs outside the main actor.
        let time = Float(state.time), level = Float(state.level)
        let bass = Float(state.bass), treble = Float(state.treble), thinking = Float(state.thinking)
        let c = state.colors.map { VoicePalette.color($0) }
        return Rectangle()
            .fill(.white)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.muistiOrb(
                    .float2(proxy.size),
                    .float(time),
                    .float(level),
                    .float(bass),
                    .float(treble),
                    .float(thinking),
                    .color(c[0]),
                    .color(c[1]),
                    .color(c[2])
                ))
            }
    }

    private func advance(to date: Date) {
        guard !reduceMotion else { return }
        state.step(to: date, phase: phase, levels: levels)
    }
}

#Preview {
    VStack {
        VoiceVisual(phase: .thinking, levels: VoiceLevels())
        VoiceVisual(phase: .idle, levels: VoiceLevels())
    }
    .padding()
}
