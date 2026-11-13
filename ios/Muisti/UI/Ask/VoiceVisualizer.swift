import SwiftUI

/// A glowing, fluid orb ringed by a live spectrum: the microphone while listening,
/// word pulses while answering, a travelling wave while thinking, slow breathing at rest.
struct VoiceVisualizer: View {
    let phase: VoiceAssistant.Phase
    let levels: VoiceLevels
    @State private var state = VisualizerState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bars around the ring; mirrored left/right so the low bands sit on top.
    private static let barCount = 72

    var body: some View {
        TimelineView(.animation(minimumInterval: phase == .idle ? 1 / 30 : 1 / 60, paused: reduceMotion)) { timeline in
            let _ = advance(to: timeline.date)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            if reduceMotion { state.snap(to: newPhase) }
        }
        .accessibilityHidden(true)
    }

    private func advance(to date: Date) {
        guard !reduceMotion else { return }
        state.step(to: date, phase: phase, mic: levels.bands, lastWordAt: levels.lastWordAt)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let t = state.time
        let energy = state.energy
        let colors = state.colors
        let orbRadius = side * 0.25 * (1 + 0.12 * energy + 0.015 * sin(t * 2.2))
        let dark = colorScheme == .dark

        // 1. Soft halo.
        let haloRadius = orbRadius * (1.9 + 0.5 * energy)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    VoicePalette.color(colors[0], opacity: (dark ? 0.45 : 0.30) * (0.55 + energy)),
                    VoicePalette.color(colors[2], opacity: dark ? 0.16 : 0.10),
                    .clear,
                ]),
                center: center, startRadius: orbRadius * 0.5, endRadius: haloRadius
            )
        )

        // 2. Spectrum ring: a blurred glow pass, then crisp bars.
        let ring = spectrumPath(center: center, orbRadius: orbRadius, side: side, time: t)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: side * 0.02))
            glow.opacity = dark ? 0.9 : 0.6
            strokeBars(ring, in: &glow, colors: colors, width: side * 0.022)
        }
        strokeBars(ring, in: &context, colors: colors, width: side * 0.011)

        // 3. Fluid orb: blobs drifting inside a clipped circle.
        let orbRect = CGRect(x: center.x - orbRadius, y: center.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2)
        context.drawLayer { orb in
            orb.clip(to: Path(ellipseIn: orbRect))
            orb.fill(Path(ellipseIn: orbRect), with: .linearGradient(
                Gradient(colors: [VoicePalette.color(colors[0]), VoicePalette.color(colors[2])]),
                startPoint: CGPoint(x: orbRect.minX, y: orbRect.minY),
                endPoint: CGPoint(x: orbRect.maxX, y: orbRect.maxY)
            ))
            orb.drawLayer { blobs in
                blobs.addFilter(.blur(radius: orbRadius * 0.32))
                blobs.blendMode = dark ? .plusLighter : .screen
                let drift = orbRadius * (0.38 + 0.35 * energy)
                let specs: [(speed: Double, phase: Double, color: Int, size: Double)] = [
                    (0.9, 0.0, 1, 0.78), (1.3, 2.1, 2, 0.70), (0.7, 4.2, 0, 0.66), (1.6, 1.0, 1, 0.48),
                ]
                for spec in specs {
                    let a = t * spec.speed + spec.phase
                    let p = CGPoint(x: center.x + cos(a) * drift, y: center.y + sin(a * 1.27) * drift)
                    let r = orbRadius * spec.size * (1 + 0.15 * energy)
                    blobs.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(VoicePalette.color(colors[spec.color], opacity: 0.9)))
                }
            }
            // Glassy highlight, top-left.
            let shine = CGPoint(x: center.x - orbRadius * 0.35, y: center.y - orbRadius * 0.45)
            orb.fill(Path(ellipseIn: orbRect), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]),
                center: shine, startRadius: 0, endRadius: orbRadius * 0.9
            ))
        }
        context.stroke(Path(ellipseIn: orbRect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(dark ? 0.25 : 0.5)), lineWidth: 1)
    }

    /// Bars as (start, end, band) triples around the orb.
    private func spectrumPath(center: CGPoint, orbRadius: CGFloat, side: CGFloat, time: Double) -> [(CGPoint, CGPoint, Int)] {
        let n = Self.barCount
        let bands = state.bars.count
        let inner = orbRadius + side * 0.045
        // Thinking: the ring slowly turns.
        let spin = phase == .thinking ? time * 0.9 : 0
        return (0..<n).map { i in
            let mirrored = i <= n / 2 ? i : n - i
            let band = min(bands - 1, mirrored * bands / (n / 2 + 1))
            let level = state.bars[band]
            let angle = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi + spin
            let length = side * (0.012 + 0.17 * level)
            let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let end = CGPoint(x: center.x + cos(angle) * (inner + length), y: center.y + sin(angle) * (inner + length))
            return (start, end, band)
        }
    }

    private func strokeBars(_ bars: [(CGPoint, CGPoint, Int)], in context: inout GraphicsContext, colors: [VoicePalette.RGB], width: CGFloat) {
        let count = Double(max(1, state.bars.count - 1))
        for (start, end, band) in bars {
            let mix = Double(band) / count
            let rgb = colors[1] * (1 - mix) + colors[2] * mix
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path,
                           with: .color(VoicePalette.color(rgb, opacity: 0.45 + 0.55 * state.bars[band])),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}

#Preview {
    VStack {
        VoiceVisualizer(phase: .thinking, levels: VoiceLevels())
        VoiceVisualizer(phase: .idle, levels: VoiceLevels())
    }
}
