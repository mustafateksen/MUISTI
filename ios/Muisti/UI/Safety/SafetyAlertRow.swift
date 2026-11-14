import SwiftUI

/// One warning: photo, message, severity and when. An open one has a "done" button;
/// more answers are in the swipe actions.
struct SafetyAlertRow: View {
    let alert: SafetyAlert
    let url: URL?
    var done: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SafetyThumbnail(url: url, title: alert.message, symbol: alert.severity.symbol, tint: alert.severity.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: Theme.Spacing.xxs) {
                    Circle().fill(alert.severity.tint).frame(width: 7, height: 7)
                    Text(alert.severity.title)
                    Text("·")
                    Text(alert.at, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let done {
                Button("Got it", systemImage: "checkmark.circle.fill", action: done)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.borderless)
            }
        }
        .opacity(done == nil ? 0.7 : 1)
    }
}
