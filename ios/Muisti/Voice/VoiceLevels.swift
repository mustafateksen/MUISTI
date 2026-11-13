import Foundation
import Observation

/// Live audio energy for the Ask visualizer: microphone bands while listening, word pulses
/// while the answer is spoken. Kept apart from `VoiceAssistant` so only the visualizer redraws.
@Observable
@MainActor
final class VoiceLevels {
    /// Microphone bands, 0…1, `SpectrumAnalyzer.bandCount` long (empty when not listening).
    private(set) var bands: [Float] = []
    /// When the synthesizer last started a word.
    private(set) var lastWordAt: Date?

    func update(_ bands: [Float]) { self.bands = bands }
    func wordSpoken() { lastWordAt = .now }

    func reset() {
        bands = []
        lastWordAt = nil
    }
}
