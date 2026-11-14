import SwiftUI

/// The summary as a list row, for systems without a navigation subtitle.
struct MemorySummaryRow: View {
    let summary: MemorySummary

    var body: some View {
        Text(summary.text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.xs, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
