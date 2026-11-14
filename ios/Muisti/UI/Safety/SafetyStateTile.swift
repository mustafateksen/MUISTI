import SwiftUI

/// One watched object: its last frame fills the tile, the state is written large on it.
struct SafetyStateTile: View {
    let state: ObjectState
    let url: URL?

    var body: some View {
        Group {
            if let url {
                KeyframeImage(url: url, maxPixel: 600, contentMode: .fill)
                    .overlay { scrim.allowsHitTesting(false) }
                    .overlay(alignment: .bottomLeading) { caption.allowsHitTesting(false) }
                    .overlay(alignment: .topLeading) { badges.allowsHitTesting(false) }
                    .opensPhotoViewer(url: url, title: SafetyNames.display(state.object))
            } else {
                LinearGradient(colors: [.ink, .brand], startPoint: .top, endPoint: .bottom)
                    .overlay(alignment: .bottomLeading) { caption }
                    .overlay(alignment: .topLeading) { badges }
            }
        }
        .frame(width: 168, height: 212)
        .clipShape(.rect(cornerRadius: Theme.Radius.inner + 4))
    }

    private var scrim: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .clear, location: 0.3),
                               .init(color: .clear, location: 0.45), .init(color: .black.opacity(0.8), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(SafetyNames.display(state.object))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text(state.state.capitalized)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(when)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(Theme.Spacing.m)
        .padding(.trailing, Theme.Spacing.l)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if state.active {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.attention, in: Circle())
                    .accessibilityLabel("Active")
            }
            if state.source != .vision {
                Label("You said", systemImage: "quote.bubble.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .font(.caption.weight(.semibold))
        .padding(Theme.Spacing.s)
    }

    private var when: String {
        let time = state.lastStateSeen.formatted(date: .omitted, time: .shortened)
        return state.place.map { "\(time) · \($0)" } ?? time
    }
}
