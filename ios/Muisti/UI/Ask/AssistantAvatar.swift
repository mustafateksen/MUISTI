import SwiftUI

/// "Muisti" with a tiny orb, above each answer.
struct AssistantAvatar: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(VoiceBadgeGradient())
                .overlay {
                    Circle().fill(.white.opacity(0.35)).frame(width: 7, height: 7).offset(x: -3, y: -3).blur(radius: 1.5)
                }
                .frame(width: 22, height: 22)
            Text("Muisti")
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
