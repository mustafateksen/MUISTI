import SwiftUI

/// Evidence frames under an answer. One frame fills the width; several page horizontally.
struct EvidenceCarousel: View {
    let hits: [MemoryHit]
    let store: MemoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label(hits.count == 1 ? String(localized: "Evidence") : String(localized: "Evidence (\(hits.count))"), systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            if hits.count == 1, let hit = hits.first {
                EvidenceCard(hit: hit, store: store)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Theme.Spacing.s) {
                        ForEach(hits) { hit in
                            EvidenceCard(hit: hit, store: store)
                                .containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }
}
