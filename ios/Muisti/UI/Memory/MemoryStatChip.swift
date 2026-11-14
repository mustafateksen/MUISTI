import SwiftUI

/// A memory-list stat: brand icon, primary text, on the grouped list's card surface.
struct MemoryStatChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s - 2)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
    }
}

#Preview {
    MemoryStatChip(text: "42 memories", systemImage: "square.stack.3d.up.fill")
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
