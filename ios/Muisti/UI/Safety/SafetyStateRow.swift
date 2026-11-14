import SwiftUI

/// What Muisti last saw of one watched object: photo, name, state, when.
struct SafetyStateRow: View {
    let state: ObjectState
    let url: URL?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SafetyThumbnail(url: url, title: SafetyNames.display(state.object), symbol: state.source == .vision ? "eye.fill" : "quote.bubble.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(SafetyNames.display(state.object))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(state.state.capitalized)
                .font(.caption.weight(.bold))
                .foregroundStyle(state.active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, 5)
                .background(state.active ? AnyShapeStyle(.attention) : AnyShapeStyle(.fill.tertiary), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [state.lastStateSeen.formatted(date: .omitted, time: .shortened)]
        if let place = state.place { parts.append(place) }
        if state.source != .vision { parts.append(String(localized: "you said")) }
        return parts.joined(separator: " · ")
    }
}
