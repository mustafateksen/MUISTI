import SwiftUI

/// What the assistant is doing, plus the live transcript.
struct AskPhaseText: View {
    let phase: VoiceAssistant.Phase
    let transcript: String
    /// The idle hint line; off once an answer is on screen.
    var showsHint = true

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                // One Text whose string changes, so phases cross-fade in place instead of overlapping.
                Text(title)
                    .font(.title3.bold())
                    .contentTransition(.opacity)
            }

            if !transcript.isEmpty, phase == .listening || phase == .thinking || phase == .speaking {
                Text("“\(transcript)”")
                    .font(.title3)
                    .multilineTextAlignment(.center)
            } else if phase == .idle, showsHint {
                Text("Gördüğün tabelaları, numaraları ve saatleri sorabilirsin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.standard, value: phase)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .listening: return "Dinliyorum…"
        case .thinking: return "Hafızanda arıyorum…"
        case .speaking: return "Cevabı okuyorum"
        default: return "Dokun ve sor"
        }
    }
}
