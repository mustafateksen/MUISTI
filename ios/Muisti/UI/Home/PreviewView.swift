import SwiftUI

/// Latest frame. In stream modes it is live; in adaptive/interval modes it is the last still
/// (there is deliberately no live video). While paused the last frame stays on screen, dimmed.
struct PreviewView: View {
    let image: UIImage?
    let state: CaptureState
    let lastFrame: FrameSummary?
    let mode: CaptureMode

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Last seen").font(.headline)
                Spacer()
                if let lastFrame {
                    Text(lastFrame.at, style: .relative)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Fixed-height box: the frame decides the size, images are overlays clipped to it.
            // (An aspect-ratio box capped by maxHeight let 3:4 content overflow the card and push
            // the layout down when the first frame arrived; portrait stream frames and landscape
            // 12 MP stills also changed the content size.)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.boxHeight)
                .overlay {
                    if let image {
                        // A box-sized carrier with the image layers as overlays: its own size (and
                        // hit/accessibility frame) is exactly the box, never the scaled-to-fill
                        // backdrop, which is taller for portrait frames, wider for landscape stills.
                        Color.clear
                            .overlay {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .blur(radius: 24)
                                    .opacity(0.55)
                            }
                            .overlay {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                            }
                            .clipped()
                            .saturation(isPaused ? 0 : 1)
                            .opacity(isPaused ? 0.6 : 1)
                    } else {
                        PreviewPlaceholder(text: placeholder, isWaiting: state == .starting || state == .waitingForDevice)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let lastFrame {
                        Label(caption(lastFrame), systemImage: lastFrame.hasLocation ? "mappin.and.ellipse" : "clock")
                            .font(.footnote.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Spacing.s)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(Theme.Spacing.s)
                    }
                }
                .background(.background.tertiary)
                .clipShape(.rect(cornerRadius: Theme.Radius.inner))
                .contentShape(.rect)
                // The box is the one VoiceOver element (its frame is exactly the box; the fill
                // backdrop's own accessibility frame overflowed the card).
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(image == nil ? [] : .isImage)
                .accessibilityLabel(image == nil ? placeholder : String(localized: "Last captured frame"))
                .accessibilityValue(lastFrame.map(caption) ?? "")
                .accessibilityIdentifier("previewBox")
                .animation(Theme.Motion.standard, value: image == nil)
        }
        .card(padding: Theme.Spacing.m)
    }

    /// Same height with and without an image, portrait or landscape.
    static let boxHeight: CGFloat = 320

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    private var placeholder: String {
        switch state {
        case .running:
            return mode.usesScheduler
                ? String(localized: "The first frame will arrive shortly.\nTo save battery there's no live video; frames are captured only when needed.")
                : String(localized: "Waiting for video…")
        case .starting:
            return String(localized: "Preparing…")
        case .waitingForDevice:
            return String(localized: "Waiting for glasses")
        default:
            return String(localized: "Once recording starts, the last frame you saw appears here.")
        }
    }

    private func caption(_ frame: FrameSummary) -> String {
        "\(frame.at.formatted(date: .omitted, time: .shortened)) · \(frame.trigger.label)"
    }
}
