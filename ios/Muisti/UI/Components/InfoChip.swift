import SwiftUI

/// Small capsule with an icon and short text: "Glasses 82%", "Location on", "12 memories".
struct InfoChip: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

#Preview {
    FlowLayout {
        InfoChip(text: "Glasses 82%", systemImage: "battery.75percent", tint: .success)
        InfoChip(text: "Location on", systemImage: "location.fill")
        InfoChip(text: "12 memories", systemImage: "square.stack.3d.up.fill", tint: .accentColor)
    }
    .padding()
}
