import SwiftUI

/// One answered warning.
struct SafetyHistoryRow: View {
    let alert: SafetyAlert
    let url: URL?

    private var answer: String {
        switch alert.response {
        case .dismissed: "Dismissed"
        case .snoozed: "Snoozed"
        case .confirmed: "Confirmed"
        case nil: ""
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Group {
                if let url {
                    KeyframeImage(url: url, maxPixel: 200, contentMode: .fill)
                        .opensPhotoViewer(url: url, title: alert.message)
                } else {
                    Image(systemName: alert.severity.symbol)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(alert.severity.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text("\(alert.at.formatted(date: .abbreviated, time: .shortened)) · \(answer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }
}
