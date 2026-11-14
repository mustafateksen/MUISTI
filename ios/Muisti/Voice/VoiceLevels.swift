import Foundation
import Observation

/// Live audio for the voice orb: the microphone while listening, the spoken answer while
/// speaking. Kept apart from `VoiceAssistant` so only the orb redraws.
@Observable
@MainActor
final class VoiceLevels {
    /// Overall loudness, 0…1.
    private(set) var level: Float = 0
    /// Voice bands, 0…1, `SpectrumAnalyzer.bandCount` long (empty when nothing is playing).
    private(set) var bands: [Float] = []
    /// When the fallback synthesizer last started a word (no spectrum on that path).
    private(set) var lastWordAt: Date?

    func update(_ frame: SpectrumAnalyzer.Frame) {
        level = frame.level
        bands = frame.bands
    }

    func wordSpoken() { lastWordAt = .now }

    func reset() {
        level = 0
        bands = []
        lastWordAt = nil
    }
}
