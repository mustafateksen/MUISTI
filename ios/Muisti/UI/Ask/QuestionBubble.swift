import SwiftUI

/// The user's question, right-aligned like a sent chat message.
struct QuestionBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s + 1)
            .background(VoiceBadgeGradient(), in: .rect(cornerRadii: .init(topLeading: 22, bottomLeading: 22, bottomTrailing: 6, topTrailing: 22), style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
            .accessibilityLabel("You: \(text)")
    }
}
