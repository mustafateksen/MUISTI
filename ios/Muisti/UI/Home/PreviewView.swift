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
                Text("Son görülen").font(.headline)
                Spacer()
                if let lastFrame {
                    Text(lastFrame.at, style: .relative)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ZStack(alignment: .bottomLeading) {
                if let image {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 24)
                            .opacity(0.55)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .saturation(isPaused ? 0 : 1)
                    .opacity(isPaused ? 0.6 : 1)
                    .accessibilityLabel("Son kaydedilen kare")
                } else {
                    PreviewPlaceholder(text: placeholder, isWaiting: state == .starting || state == .waitingForDevice)
                }

                if let lastFrame {
                    Label(caption(lastFrame), systemImage: lastFrame.hasLocation ? "mappin.and.ellipse" : "clock")
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(Theme.Spacing.s)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxHeight: 440)
            .background(.background.tertiary)
            .clipShape(.rect(cornerRadius: Theme.Radius.inner))
            .animation(Theme.Motion.standard, value: image == nil)
        }
        .card(padding: Theme.Spacing.m)
    }

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    private var placeholder: String {
        switch state {
        case .running:
            return mode.usesScheduler
                ? "İlk kare birazdan gelir.\nPil için canlı video yok; yalnızca gerekli anlarda kare alınır."
                : "Görüntü geliyor…"
        case .starting:
            return "Hazırlanıyor…"
        case .waitingForDevice:
            return "Gözlük bekleniyor"
        default:
            return "Kayıt başlayınca son gördüğün kare burada görünür."
        }
    }

    private func caption(_ frame: FrameSummary) -> String {
        "\(frame.at.formatted(date: .omitted, time: .shortened)) · \(frame.trigger.label)"
    }
}
