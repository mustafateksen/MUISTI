import SwiftUI

/// End-user status: one clear headline, one sentence, a few chips.
struct StatusCard: View {
    let status: HomeStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                StatusGlyph(symbol: status.symbol, tone: status.tone, animate: !reduceMotion)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(status.title)
                        .font(.title2.bold())
                        .contentTransition(.opacity)
                    Text(status.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FlowLayout {
                ForEach(status.chips) { chip in
                    InfoChip(text: chip.text, systemImage: chip.systemImage, tint: chip.tint)
                }
            }

            if let warning = status.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .animation(Theme.Motion.standard, value: status.title)
        .accessibilityElement(children: .combine)
    }
}
