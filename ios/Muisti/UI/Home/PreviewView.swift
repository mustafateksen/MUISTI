import SwiftUI

/// Latest frame. In stream modes it is live; in adaptive/interval modes it is the last still
/// (there is deliberately no live video). While paused the last frame stays on screen.
struct PreviewView: View {
    let image: UIImage?
    let state: CaptureState
    let lastFrame: FrameSummary?
    let mode: CaptureMode

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(isPaused ? 0.55 : 1)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eyeglasses").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(placeholder).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let lastFrame {
                Text(caption(lastFrame))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 460)
    }

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    private var placeholder: String {
        switch state {
        case .running:
            return mode.usesScheduler ? "Çalışıyor. İlk kare birazdan gelir.\nCanlı video yok; pil için yalnızca gerekli anlarda kare alınır." : "Akış başlıyor…"
        case .waitingForDevice: return "Gözlük bekleniyor.\nAçık, menteşesi açık ve yakında olmalı."
        default: return state.label
        }
    }

    private func caption(_ f: FrameSummary) -> String {
        let time = f.at.formatted(date: .omitted, time: .standard)
        return "\(time) · \(f.width)×\(f.height) · \(f.trigger.label)\(f.hasLocation ? " · 📍" : "")"
    }
}
