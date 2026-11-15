@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Observation
import os

/// How a spoken question is heard. Chosen in Settings › Microphone test, where one recording
/// is run through every engine side by side.
enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    /// Parakeet when its model is in the app, Apple's on-device model otherwise. Every engine
    /// runs on the phone: the audio of a question is never sent anywhere.
    case automatic
    /// NVIDIA Parakeet (CoreML, on the phone): the whole utterance is re-read every moment,
    /// so later words correct earlier ones. English and 24 other European languages.
    case parakeet
    /// Apple's on-device models (`SpeechAnalyzer`, or `SFSpeechRecognizer` before iOS 26).
    case apple

    var id: String { rawValue }
}

/// Speech settings (UserDefaults; read where a listening session starts).
enum SpeechSettings {
    private static var store: UserDefaults { .standard }

    static var engine: SpeechEngine {
        get { store.string(forKey: "speech.engine").flatMap(SpeechEngine.init) ?? .automatic }
        set { store.set(newValue.rawValue, forKey: "speech.engine") }
    }
    /// The speech/no-speech model decides when the user has stopped; off: loudness only.
    static var neuralEndpoint: Bool {
        get { store.object(forKey: "speech.neuralEndpoint") as? Bool ?? true }
        set { store.set(newValue, forKey: "speech.neuralEndpoint") }
    }
    /// iOS voice processing on the phone's or headset's microphone (noise suppression, gain).
    static var voiceProcessing: Bool {
        get { store.bool(forKey: "speech.voiceProcessing") }
        set { store.set(newValue, forKey: "speech.voiceProcessing") }
    }
    /// Seconds of no speech that end a question.
    static var endSilence: Double {
        get { store.object(forKey: "speech.endSilence") as? Double ?? 1.1 }
        set { store.set(newValue, forKey: "speech.endSilence") }
    }

    /// Languages Parakeet (v3 family) reads; anything else stays with Apple.
    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
        "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static func parakeetReads(_ localeIdentifier: String) -> Bool {
        parakeetLanguages.contains(String(localeIdentifier.prefix(2)).lowercased())
    }
}

/// What the screen shows about the on-device models.
@MainActor
@Observable
final class SpeechModelStatus {
    static let shared = SpeechModelStatus()
    enum Phase: Equatable { case missing, loading, ready, failed(String) }
    var parakeet: Phase = .missing
    var endpoint: Phase = .missing
}

/// The on-device speech models from FluidAudio: Parakeet for the words, Silero for
/// "is someone speaking". Loaded once, shared by every listening session.
actor SpeechLab {
    static let shared = SpeechLab()

    /// English has its own model (Parakeet v2, English only): the multilingual one can slide
    /// into another language on accented or noisy English ("Jamus olvis…", measured 15 Nov).
    enum Family: String, Sendable {
        case english = "ParakeetEN"
        case european = "ParakeetEU"

        static func of(_ localeIdentifier: String) -> Family {
            localeIdentifier.lowercased().hasPrefix("en") ? .english : .european
        }
        var version: AsrModelVersion { self == .english ? .v2 : .ultra }
    }

    private var asr: [Family: AsrManager] = [:]
    private var vad: VadManager?
    private var loadingASR: [Family: Task<Bool, Never>] = [:]
    private var loadingVAD: Task<Bool, Never>?

    /// The models ship inside the app (`Resources/SpeechModels/*.bundle`, put there at build
    /// time and kept out of git): nothing is downloaded on the phone and no audio leaves it.
    nonisolated static func bundle(_ name: String) -> URL? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The Parakeet files for this language are in this build.
    nonisolated static func parakeetBundled(_ localeIdentifier: String) -> Bool {
        bundle(Family.of(localeIdentifier).rawValue).map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Encoder.mlmodelc").path) } ?? false
    }

    nonisolated static var endpointBundled: Bool { bundle("SpeechDetector") != nil }

    func parakeetReady(_ localeIdentifier: String) -> Bool { asr[Family.of(localeIdentifier)] != nil }
    var endpointReady: Bool { vad != nil }

    /// Loads the speech/no-speech model.
    @discardableResult
    func prepareEndpoint() async -> Bool {
        if vad != nil { return true }
        if let loadingVAD { return await loadingVAD.value }
        let task = Task { () -> Bool in
            guard let url = Self.bundle("SpeechDetector")?.appendingPathComponent("silero-vad-unified-256ms-v6.2.1.mlmodelc") else {
                await MainActor.run { SpeechModelStatus.shared.endpoint = .missing }
                return false
            }
            await MainActor.run { SpeechModelStatus.shared.endpoint = .loading }
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuOnly
                let model = try MLModel(contentsOf: url, configuration: configuration)
                self.setVAD(VadManager(config: .default, vadModel: model))
                await MainActor.run { SpeechModelStatus.shared.endpoint = .ready }
                return true
            } catch {
                Log.pipeline.error("speech: the endpoint model did not load: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { SpeechModelStatus.shared.endpoint = .failed(error.localizedDescription) }
                return false
            }
        }
        loadingVAD = task
        let ok = await task.value
        loadingVAD = nil
        return ok
    }

    private func setVAD(_ manager: VadManager) { vad = manager }
    private func setASR(_ family: Family, _ manager: AsrManager) { asr[family] = manager }

    /// Loads Parakeet for a language from the app bundle (the first load on a phone compiles
    /// it for its chip and can take a while; later ones take a second or two).
    @discardableResult
    func prepareParakeet(_ localeIdentifier: String) async -> Bool {
        let family = Family.of(localeIdentifier)
        if asr[family] != nil { return true }
        if let loading = loadingASR[family] { return await loading.value }
        guard Self.parakeetBundled(localeIdentifier), let directory = Self.bundle(family.rawValue) else {
            await MainActor.run { SpeechModelStatus.shared.parakeet = .missing }
            return false
        }
        let task = Task { () -> Bool in
            await MainActor.run { SpeechModelStatus.shared.parakeet = .loading }
            do {
                let began = Date()
                let models = try AsrModels.loadLocal(from: directory, version: family.version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // The first run warms the model up: do it now, not on the first question.
                _ = try? await self.run(manager, [Float](repeating: 0, count: 16_000))
                self.setASR(family, manager)
                Log.pipeline.info("speech: \(family.rawValue, privacy: .public) ready in \(String(format: "%.1f", Date().timeIntervalSince(began)), privacy: .public) s")
                await MainActor.run { SpeechModelStatus.shared.parakeet = .ready }
                return true
            } catch {
                Log.pipeline.error("speech: Parakeet did not load: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { SpeechModelStatus.shared.parakeet = .failed(error.localizedDescription) }
                return false
            }
        }
        loadingASR[family] = task
        let ok = await task.value
        loadingASR[family] = nil
        return ok
    }

    private func run(_ manager: AsrManager, _ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make()
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    /// 16 kHz mono samples → text. nil when the model is not loaded or the call failed.
    func transcribe(_ samples: [Float], localeIdentifier: String) async -> String? {
        guard let asr = asr[Family.of(localeIdentifier)], samples.count >= 4_000 else { return nil }
        // The model wants at least a second of audio: short clips are padded with silence.
        var padded = samples
        if padded.count < 16_000 { padded += [Float](repeating: 0, count: 16_000 - padded.count) }
        do {
            return try await run(asr, padded).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.pipeline.error("speech: Parakeet failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// One 256 ms hop (4096 samples at 16 kHz) through the speech/no-speech model.
    func speechProbability(_ chunk: [Float], state: VadStreamState) async -> (probability: Float, state: VadStreamState)? {
        guard let vad, let result = try? await vad.processStreamingChunk(chunk, state: state) else { return nil }
        return (result.probability, result.state)
    }

    /// Speech probability per 256 ms hop of a whole recording (the microphone test's trace).
    func speechTrace(_ samples: [Float]) async -> [Float] {
        guard let vad, let results = try? await vad.process(samples) else { return [] }
        return results.map(\.probability)
    }
}

/// Any microphone format → 16 kHz mono Float32, the format of both models. Audio thread safe.
final class Resampler16k: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return [] }
        let target = Self.format
        if buffer.format == target, let data = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

/// "Is the user speaking?" for a live session: the speech/no-speech model when it is loaded
/// (it tells a voice from a street, a fan or music, which loudness cannot), loudness until
/// then. `onVoice` is called, at most a few times a second, while speech is heard.
final class VoiceGate: @unchecked Sendable {
    /// Speech, but whose? The glasses and the phone are far closer to the user than to anyone
    /// else, so their voice is the loud one: once it has been heard, speech much quieter than
    /// it (people talking nearby, a television) no longer counts as the user still speaking.
    struct Judge: Sendable {
        /// The loudest speech so far, dBFS per 256 ms.
        private(set) var loudest: Float = -120
        private var heard = 0
        /// Speech this far below the user's own level is someone else.
        static let othersBelow: Float = 12

        mutating func isUser(probability: Float, samples: [Float]) -> Bool {
            guard probability >= VoiceGate.threshold, !samples.isEmpty else { return false }
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            let level = 10 * log10(max(sum / Float(samples.count), 1e-12))
            heard += 1
            if level > loudest { loudest = level }
            // The first moments set the level; nothing is ruled out before that.
            return heard <= 3 || level >= loudest - Self.othersBelow
        }
    }

    private struct State {
        var pending: [Float] = []
        var stream = VadStreamState.initial()
        var busy = false
        var voicedHops = 0
        var hops = 0
        var judge = Judge()
        var lastUserHop = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let loudness = VoiceActivity()
    private let neural: Bool
    private let onVoice: @Sendable () -> Void
    /// Speech probability a hop needs to count as voice.
    static let threshold: Float = 0.5

    init(neural: Bool = SpeechSettings.neuralEndpoint, onVoice: @escaping @Sendable () -> Void) {
        self.neural = neural
        self.onVoice = onVoice
    }

    /// Seconds of speech heard so far (neural mode only).
    var voicedSeconds: Double { state.withLock { Double($0.voicedHops) * 0.256 } }
    var usedNeural: Bool { state.withLock { $0.hops > 0 } }
    /// Where the user's own speech ends so far, in samples from the start (neural mode).
    var userSpeechEnd: Int { state.withLock { $0.lastUserHop * 4096 } }

    /// 16 kHz mono samples, from the audio thread.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let chunk = state.withLock { s -> [Float]? in
            s.pending += samples
            guard neural, !s.busy, s.pending.count >= 4096 else { return nil }
            s.busy = true
            let chunk = Array(s.pending.prefix(4096))
            s.pending.removeFirst(4096)
            return chunk
        }
        if let chunk {
            Task { await self.judge(chunk) }
        } else if !neural || !state.withLock({ $0.hops > 0 || $0.busy }) {
            loudnessFallback(samples)
        }
    }

    private func judge(_ first: [Float]) async {
        var chunk: [Float]? = first
        while let now = chunk {
            let stream = state.withLock { $0.stream }
            let result = await SpeechLab.shared.speechProbability(now, state: stream)
            let heard = now
            var voiced = false
            let verdict = state.withLock { s -> (Bool, [Float]?) in
                var mine = false
                if let result {
                    s.stream = result.state
                    s.hops += 1
                    mine = s.judge.isUser(probability: result.probability, samples: heard)
                    if mine {
                        s.voicedHops += 1
                        s.lastUserHop = s.hops
                    }
                }
                // No model: stop asking for this session (loudness takes over in `feed`).
                guard result != nil, s.pending.count >= 4096 else {
                    s.busy = false
                    if result == nil { s.pending.removeAll(keepingCapacity: true) }
                    return (mine, nil)
                }
                let next = Array(s.pending.prefix(4096))
                s.pending.removeFirst(4096)
                return (mine, next)
            }
            voiced = verdict.0
            chunk = verdict.1
            if voiced { onVoice() }
        }
    }

    private func loudnessFallback(_ samples: [Float]) {
        state.withLock { s in if s.pending.count > 16_000 { s.pending.removeFirst(s.pending.count - 16_000) } }
        guard let buffer = Resampler16k.buffer(samples), loudness.isVoice(buffer) else { return }
        onVoice()
    }
}
