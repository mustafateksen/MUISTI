import SwiftUI

/// A small coloured dot; pulses while recording or while something needs attention.
struct StatusDot: View {
    let tint: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tint == .secondary ? Color.gray : tint)
            .frame(width: 8, height: 8)
            .background {
                if pulsing, !reduceMotion {
                    Circle()
                        .fill(tint)
                        .phaseAnimator([false, true]) { circle, on in
                            circle
                                .scaleEffect(on ? 2.4 : 1)
                                .opacity(on ? 0 : 0.6)
                        } animation: { on in
                            on ? .easeOut(duration: 1.4) : .linear(duration: 0.01)
                        }
                }
            }
            .accessibilityHidden(true)
    }
}
