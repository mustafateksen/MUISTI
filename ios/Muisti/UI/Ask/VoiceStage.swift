import SwiftUI

/// Voice mode, filling the chat area: the orb, what the assistant is doing, and live captions
/// (your words while listening, the answer while it is read aloud). With an empty chat it is
/// also the welcome screen, with a few example questions.
struct VoiceStage: View {
    let voice: VoiceAssistant
    let showsSuggestions: Bool
    let onOrbTap: () -> Void
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: 0)

            Button(action: onOrbTap) {
                VoiceVisual(phase: voice.phase, levels: voice.levels)
                    .frame(maxWidth: 300, maxHeight: 340)
                    .contentShape(Circle().scale(0.7))
            }
            .buttonStyle(OrbPressStyle())
            .disabled(voice.phase == .thinking)
            .accessibilityLabel(orbLabel)
            .accessibilityInputLabels([Text("Ask"), Text("Listen"), Text("Microphone")])
            .sensoryFeedback(.impact(weight: .medium), trigger: voice.phase == .listening)

            VStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                caption
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if showsSuggestions, !voice.isBusy {
                SuggestionList(onSelect: onSuggestion)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
        .animation(Theme.Motion.standard, value: voice.phase)
        .animation(Theme.Motion.standard, value: voice.transcript)
    }

    @ViewBuilder
    private var caption: some View {
        switch voice.phase {
        case .listening:
            Text(voice.transcript.isEmpty ? String(localized: "I'm listening") : voice.transcript)
                .font(.title3)
                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(4)
        case .thinking:
            Text(voice.transcript)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        case .speaking:
            if let answer = voice.lastResult?.answer {
                ScrollView {
                    Text(answer)
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 160)
                .scrollBounceBehavior(.basedOnSize)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.attention)
        case .idle:
            Text("Ask about signs, numbers, and times you've seen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch voice.phase {
        case .listening: String(localized: "Listening")
        case .thinking: String(localized: "Searching your memory…")
        case .speaking: "Muisti"
        case .failed: String(localized: "Something went wrong")
        case .idle: String(localized: "Tap to ask")
        }
    }

    private var orbLabel: String {
        switch voice.phase {
        case .listening: String(localized: "Stop listening")
        case .speaking: String(localized: "Stop reading")
        default: String(localized: "Ask by voice")
        }
    }
}

/// Gentle squeeze while the orb is pressed.
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}
