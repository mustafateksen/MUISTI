import Foundation

/// Per-frame smoothing for the voice orb: values rise fast and fall slowly (the "alive" feel),
/// colours and motion speed glide between phases. A plain class: it changes every frame and
/// must not trigger SwiftUI updates itself.
@MainActor
final class VisualizerState {
    private(set) var bars = [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var colors = VoicePalette.colors(for: .idle)
    private(set) var level = 0.0
    private(set) var bass = 0.0
    private(set) var treble = 0.0
    private(set) var thinking = 0.0
    /// Phase-speed-weighted clock for the shader.
    private(set) var time = 0.0
    private var speed = 0.6
    private var last: Date?

    private static let attack = 40.0
    private static let release = 8.0

    func step(to date: Date, phase: VoiceAssistant.Phase, levels: VoiceLevels) {
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), 0.1)
        last = date
        let live = levels.bands

        let targetSpeed: Double = switch phase {
        case .listening: 1.1
        case .thinking: 2.2
        case .speaking: 1.5
        case .failed: 0.3
        case .idle: 0.6
        }
        speed += (targetSpeed - speed) * blend(dt, rate: 3)
        time += dt * speed
        if time > 3_600 { time -= 3_600 }

        let word = levels.lastWordAt.map { exp(-date.timeIntervalSince($0) * 3.2) } ?? 0
        var targetLevel: Double
        switch phase {
        case .listening, .speaking where !live.isEmpty:
            targetLevel = Double(levels.level)
        case .speaking:
            targetLevel = 0.2 + 0.5 * word
        case .thinking:
            targetLevel = 0.18
        case .idle:
            targetLevel = 0.05 + 0.03 * sin(time * 2)
        case .failed:
            targetLevel = 0
        }

        let n = bars.count
        for i in 0..<n {
            let x = Double(i)
            let target: Double = switch phase {
            case _ where !live.isEmpty && i < live.count:
                Double(live[i])
            case .speaking:
                (0.15 + 0.6 * word) * (0.5 + 0.5 * abs(sin(time * 4.1 + x * 0.55))) * (1 - x / Double(n) * 0.5)
            case .thinking:
                0.08 + 0.22 * pow(max(0, sin(time * 2.4 - x * 0.45)), 3)
            case .idle:
                0.03 + 0.03 * (1 + sin(time * 1.6 + x * 0.5))
            default:
                0.02
            }
            bars[i] += (target - bars[i]) * blend(dt, rate: target > bars[i] ? Self.attack : Self.release)
        }

        level += (targetLevel - level) * blend(dt, rate: targetLevel > level ? Self.attack : Self.release)
        let lowCount = n / 4
        let targetBass = bars.prefix(lowCount).reduce(0, +) / Double(lowCount)
        let targetTreble = bars.suffix(n / 3).reduce(0, +) / Double(n / 3)
        bass += (targetBass - bass) * blend(dt, rate: 14)
        treble += (targetTreble - treble) * blend(dt, rate: 14)
        thinking += ((phase == .thinking ? 1 : 0) - thinking) * blend(dt, rate: 4)

        let goal = VoicePalette.colors(for: phase)
        let colorBlend = blend(dt, rate: 3.5)
        for i in colors.indices { colors[i] += (goal[i] - colors[i]) * colorBlend }
    }

    /// Jump straight to a phase's resting look (Reduce Motion: no per-frame animation).
    func snap(to phase: VoiceAssistant.Phase) {
        colors = VoicePalette.colors(for: phase)
        level = phase == .listening ? 0.3 : 0.08
        thinking = phase == .thinking ? 1 : 0
        bars = bars.map { _ in 0.08 }
    }

    private func blend(_ dt: Double, rate: Double) -> Double { 1 - exp(-rate * dt) }
}
