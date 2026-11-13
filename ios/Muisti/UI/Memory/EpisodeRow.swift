import SwiftUI

/// One memory episode (a walk or visit) in the memory list, shown like a folder.
struct EpisodeRow: View {
    let episode: MemoryEpisode
    let store: MemoryStore

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack(alignment: .bottomTrailing) {
                if let cover = store.coverURL(episode) {
                    KeyframeImage(url: cover, maxPixel: 240)
                } else {
                    Rectangle().fill(.background.tertiary)
                }
                // Compact badge that always fits the 72 pt cover (a Label was wider and spilled out).
                HStack(spacing: 2) {
                    Image(systemName: "photo.stack")
                    Text("\(episode.frameCount)")
                }
                .font(.caption2.bold().monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
                .accessibilityLabel("\(episode.frameCount) kare")
            }
            .frame(width: 72, height: 88)
            .clipShape(.rect(cornerRadius: Theme.Radius.small))

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(episode.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let summary = episode.summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        // One element with the row's own frame (`.combine` also took in the scaled-to-fill
        // cover photo, whose frame is wider than the clipped thumbnail).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([episode.displayTitle, subtitle, "\(episode.frameCount) kare", episode.summary].compactMap { $0 }.joined(separator: ", "))
    }

    private var subtitle: String {
        let start = episode.startedAt.formatted(date: .omitted, time: .shortened)
        let end = episode.endedAt.formatted(date: .omitted, time: .shortened)
        let span = start == end ? start : "\(start)–\(end)"
        return episode.street.map { "\(span) · \($0)" } ?? span
    }
}
