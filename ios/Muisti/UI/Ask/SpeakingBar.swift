import SwiftUI

/// While Muisti reads the answer aloud: the orb, small, where the composer was, so the answer
/// and its evidence stay readable above it.
struct SpeakingBar: View {
    let voice: VoiceAssistant

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            VoiceVisual(phase: voice.phase, levels: voice.levels)
                .frame(width: 96, height: 96)
                .padding(-24)   // the glow spills outside the capsule; the orb itself is ~48 pt
                .frame(width: 48, height: 48)
                .padding(.leading, Theme.Spacing.xs)

            Text("Muisti is speaking")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: voice.cancel) {
                Label("Stop", systemImage: "speaker.slash.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(minHeight: 44)
                    .background(.fill.tertiary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.xs)
        .glassCapsule()
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .contain)
    }
}
