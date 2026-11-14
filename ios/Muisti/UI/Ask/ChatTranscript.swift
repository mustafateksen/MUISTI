import SwiftUI

/// The conversation, oldest first: question bubbles on the right, Muisti's answers with their
/// evidence on the left. (While Muisti listens, thinks or speaks, voice mode replaces this.)
struct ChatTranscript: View {
    let voice: VoiceAssistant
    let store: MemoryStore

    var body: some View {
        LazyVStack(spacing: Theme.Spacing.l) {
            ForEach(voice.history.reversed()) { result in
                VStack(spacing: Theme.Spacing.s) {
                    QuestionBubble(text: result.question)
                    AssistantAvatar()
                        .padding(.top, Theme.Spacing.xs)
                    AnswerCard(result: result, store: store, showsQuestion: false)
                }
                .id(result.id)
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
