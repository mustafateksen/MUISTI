import SwiftUI

/// The conversation, oldest first: question bubbles on the right, Muisti's answers with their
/// evidence on the left. (While Muisti listens, thinks or speaks, voice mode replaces this.)
struct ChatTranscript: View {
    let voice: VoiceAssistant
    let store: MemoryStore
    /// A typed question still being answered.
    var pending: String?

    var body: some View {
        LazyVStack(spacing: Theme.Spacing.l) {
            ForEach(voice.history.reversed()) { result in
                VStack(spacing: Theme.Spacing.s) {
                    if !result.spontaneous { QuestionBubble(text: result.question) }
                    AssistantAvatar()
                        .padding(.top, Theme.Spacing.xs)
                    AnswerCard(result: result, store: store, showsQuestion: false)
                }
                .id(result.id)
            }

            if let pending, voice.history.first?.question != pending || voice.phase == .thinking {
                VStack(spacing: Theme.Spacing.s) {
                    QuestionBubble(text: pending)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        AssistantAvatar()
                        TypingDots()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.xs)
                }
                .id("pending")
                .transition(.opacity)
            }

            if case .failed(let message) = voice.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Three dots pulsing while Muisti thinks about a typed question.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
        }
        .accessibilityLabel("Muisti is thinking")
    }
}
