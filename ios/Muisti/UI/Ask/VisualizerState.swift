import Foundation

/// Per-frame smoothing for `VoiceVisualizer`: bars rise fast and fall slowly, colours and
/// energy glide between phases. A plain class: it changes every frame and must not trigger
/// SwiftUI updates itself.
@MainActor
final class VisualizerState {
    private(set) var bars = [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var colors = VoicePalette.colors(for: .idle)
    private(set) var energy = 0.1
    /// Phase-speed-weighted clock that drives orbiting and waves.
    private(set) var time = 0.0
    private var last: Date?

    func step(to date: Date, phase: VoiceAssistant.Phase, mic: [Float], lastWordAt: Date?) {
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), 0.1)
        last = date

        let speed: Double = switch phase {
        case .listening: 1.0
        case .thinking: 1.7
        case .speaking: 1.25
        case .failed: 0.2
        case .idle: 0.55
        }
        time += dt * speed

        let word = lastWordAt.map { exp(-date.timeIntervalSince($0) * 3.2) } ?? 0
        let count = bars.count
        var targetEnergy = 0.1
        for i in 0..<count {
            let x = Double(i)
            let target: Double
            switch phase {
            case .listening:
                target = i < mic.count ? Double(mic[i]) : 0.04 + 0.03 * sin(time * 3 + x * 0.7)
            case .speaking:
                let shape = 0.45 + 0.55 * abs(sin(time * 4.1 + x * 0.55) * cos(time * 2.3 - x * 0.31))
                target = (0.18 + 0.72 * word) * shape * (1 - x / Double(count) * 0.45)
            case .thinking:
                target = 0.12 + 0.30 * pow(max(0, sin(time * 2.6 - x * 0.45)), 3)
            case .idle:
                target = 0.05 + 0.04 * (1 + sin(time * 1.4 + x * 0.5))
            case .failed:
                target = 0.03
            }
            let rate = target > bars[i] ? 22.0 : 7.0
            bars[i] += (target - bars[i]) * (1 - exp(-rate * dt))
        }

        switch phase {
        case .listening:
            let voiced = mic.isEmpty ? 0 : Double(mic.prefix(20).reduce(0, +)) / 20
            targetEnergy = min(1, max(0.15, voiced * 1.4))
        case .speaking: targetEnergy = 0.25 + 0.6 * word
        case .thinking: targetEnergy = 0.35
        case .idle: targetEnergy = 0.12
        case .failed: targetEnergy = 0.05
        }
        energy += (targetEnergy - energy) * (1 - exp(-9 * dt))

        let goal = VoicePalette.colors(for: phase)
        let blend = 1 - exp(-4 * dt)
        for i in colors.indices { colors[i] += (goal[i] - colors[i]) * blend }
    }

    /// Jump straight to a phase's resting look (Reduce Motion: no per-frame animation).
    func snap(to phase: VoiceAssistant.Phase) {
        colors = VoicePalette.colors(for: phase)
        energy = phase == .listening ? 0.4 : 0.12
        let rest: Double = if case .failed = phase { 0.03 } else { 0.12 }
        bars = bars.map { _ in rest }
    }
}
