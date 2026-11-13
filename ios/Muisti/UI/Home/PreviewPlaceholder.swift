import SwiftUI

/// Empty preview: an icon and one friendly sentence.
struct PreviewPlaceholder: View {
    let text: String
    let isWaiting: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, isActive: isWaiting)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
