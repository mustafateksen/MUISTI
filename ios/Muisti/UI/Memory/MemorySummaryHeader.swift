import SwiftUI

/// Three numbers at the top of the memory list.
struct MemorySummaryHeader: View {
    let total: Int
    let pending: Int
    let retentionDays: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            stat(value: "\(total)", label: "anı", icon: "square.stack.3d.up.fill", tint: .accentColor)
            stat(value: "\(pending)", label: "işleniyor", icon: "sparkles", tint: .purple)
            stat(value: "\(retentionDays) gün", label: "saklanır", icon: "clock.arrow.circlepath", tint: .blue)
        }
    }

    private func stat(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // Equal shares of the row: three cards never add up to more than the screen.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .card(radius: Theme.Radius.inner, padding: Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    MemorySummaryHeader(total: 42, pending: 3, retentionDays: 7)
        .padding()
}
