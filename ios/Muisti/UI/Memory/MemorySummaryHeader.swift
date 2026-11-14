import SwiftUI

/// One quiet line of chips at the top of the memory list.
struct MemorySummaryHeader: View {
    let total: Int
    let pending: Int
    let retentionDays: Int

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.xs) {
            InfoChip(text: total == 1 ? "1 memory" : "\(total) memories", systemImage: "square.stack.3d.up.fill", tint: .brand)
            if pending > 0 {
                InfoChip(text: "\(pending) processing", systemImage: "sparkles", tint: .brandViolet)
            }
            InfoChip(text: retentionDays == 1 ? "Kept 1 day" : "Kept \(retentionDays) days", systemImage: "clock.arrow.circlepath")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    MemorySummaryHeader(total: 42, pending: 3, retentionDays: 7)
        .padding()
}
