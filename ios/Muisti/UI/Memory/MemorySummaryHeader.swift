import SwiftUI

/// One quiet line of chips at the top of the memory list, on the same white surface as the
/// cards below so it reads as part of the page.
struct MemorySummaryHeader: View {
    let total: Int
    let pending: Int
    let retentionDays: Int

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.xs) {
            MemoryStatChip(text: total == 1 ? "1 memory" : "\(total) memories", systemImage: "square.stack.3d.up.fill")
            if pending > 0 {
                MemoryStatChip(text: "\(pending) processing", systemImage: "sparkles")
            }
            MemoryStatChip(text: retentionDays == 1 ? "Kept 1 day" : "Kept \(retentionDays) days", systemImage: "clock.arrow.circlepath")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    List {
        MemorySummaryHeader(total: 42, pending: 3, retentionDays: 7)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}
