import SwiftUI

/// Bottom of voice mode: one clear way out (cancel listening, or stop reading the answer).
struct VoiceControls: View {
    let phase: VoiceAssistant.Phase
    let onCancel: () -> Void

    var body: some View {
        HStack {
            switch phase {
            case .listening:
                control("Cancel", systemImage: "xmark")
            case .speaking:
                control("Stop", systemImage: "speaker.slash.fill")
            default:
                ProgressView()
                    .frame(height: 56)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func control(_ title: String, systemImage: String) -> some View {
        Button(action: onCancel) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.xl)
                .frame(minHeight: 56)
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .transition(.scale.combined(with: .opacity))
    }
}
