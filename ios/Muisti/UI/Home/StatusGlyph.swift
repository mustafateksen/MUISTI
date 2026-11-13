import SwiftUI

/// Round status icon. While recording it breathes with a soft halo.
struct StatusGlyph: View {
    let symbol: String
    let tone: HomeStatus.Tone
    let animate: Bool

    var body: some View {
        ZStack {
            if tone == .active, animate {
                Circle()
                    .fill(tone.color.opacity(0.25))
                    .phaseAnimator([false, true]) { halo, expanded in
                        halo
                            .scaleEffect(expanded ? 1.35 : 1)
                            .opacity(expanded ? 0 : 1)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.6) : .linear(duration: 0.01)
                    }
            }
            Circle()
                .fill(tone.color.opacity(tone == .idle ? 0.12 : 0.18))
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tone == .idle ? Color.accentColor : tone.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        StatusGlyph(symbol: "eyeglasses", tone: .active, animate: true)
        StatusGlyph(symbol: "eyeglasses", tone: .idle, animate: true)
        StatusGlyph(symbol: "pause.circle", tone: .attention, animate: true)
    }
}
