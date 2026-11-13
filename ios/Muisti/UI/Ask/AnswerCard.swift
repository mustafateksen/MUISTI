import SwiftUI

/// The answer, whether it was actually seen, and the frames that prove it.
struct AnswerCard: View {
    let result: AskResult
    let store: MemoryStore
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    private var seen: Bool { result.label == .seen }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Label(result.label.title, systemImage: seen ? "checkmark.seal.fill" : "questionmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(seen ? .green : .orange)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background((seen ? Color.green : .orange).opacity(0.14), in: Capsule())
                Spacer()
                ShareLink(item: result.answer) {
                    Label("Paylaş", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
            }

            Text(result.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(result.answer)
                .font(.title2.bold())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let note = result.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if developerMode {
                Text("\(result.latencyMs) ms · \(result.usedAI ? "Nemotron" : "yerel arama")")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                if let trace = result.trace {
                    Text(trace)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if !result.evidence.isEmpty {
                EvidenceCarousel(hits: result.evidence, store: store)
            }
        }
        .card()
    }
}
