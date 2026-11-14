import SwiftUI

/// The answer, whether it was actually seen, and the frames that prove it.
struct AnswerCard: View {
    let result: AskResult
    let store: MemoryStore
    /// Off in the chat, where the question is already shown as its own bubble.
    var showsQuestion = true
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    private var seen: Bool { result.label == .seen }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // Verdict chip only for answers about something seen; chat and commands have none.
            // Share / copy live in the long-press menu (no empty header row).
            if !result.isCommand {
                Label {
                    (seen ? Text("Seen") : result.label == .unsure ? Text("Not sure") : Text("Not seen"))
                        .foregroundStyle(seen ? Color.success : Color.primary)
                } icon: {
                    Image(systemName: seen ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(seen ? Color.success : Color.attention)
                }
                .font(.subheadline.bold())
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xxs)
                .background((seen ? Color.success : .attention).opacity(seen ? 0.16 : 0.22), in: Capsule())
            }

            if showsQuestion {
                Text(result.question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
                Text("\(result.latencyMs) ms · \(result.usedAI ? "Nemotron" : "local search")")
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

            // The live view the answer looked at (faces masked).
            if let live = result.liveFrame, let image = UIImage(data: live) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label("Live view", systemImage: "eye")
                        .font(.subheadline.bold())
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("What the glasses saw for this answer")
                }
            }

            // Safety log frames the answer or warning relies on (blurred, on the phone).
            if !result.safetyFrames.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(result.safetyFrames, id: \.self) { url in
                            SafetyFrameThumb(url: url)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .card()
        .contextMenu {
            ShareLink(item: result.answer) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = result.answer }
        }
    }
}

/// A blurred evidence frame from the safety log.
private struct SafetyFrameThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 160, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Evidence frame")
        .task(id: url) {
            let url = url
            image = await Task.detached { (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) }.value
        }
    }
}
