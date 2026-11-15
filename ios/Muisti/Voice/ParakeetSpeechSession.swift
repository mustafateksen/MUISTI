@preconcurrency import AVFoundation
import Foundation
import os
import Speech

/// Where a listening session or a test recording takes its audio from.
enum MicSource: Sendable {
    /// The iPhone's or the connected headset's microphone (AVAudioEngine).
    case microphone
    /// The glasses microphone inside the camera stream.
    case glasses(GlassesMicTap)
}

/// Opens a microphone and hands out 16 kHz mono samples. Shared by the Parakeet session and
/// the microphone test.
final class MicCapture: @unchecked Sendable {
    private let source: MicSource
    private let audioEngine = AVAudioEngine()
    private let resampler = Resampler16k()

    init(source: MicSource) { self.source = source }

    /// `onSamples` runs on the audio thread.
    func start(onSamples: @escaping @Sendable ([Float]) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws {
        let resampler = resampler
        let spectrum = SpectrumAnalyzer()
        switch source {
        case .glasses(let tap):
            tap.setConsumer { buffer in
                onSamples(resampler.convert(buffer))
                if let frame = spectrum.process(buffer) { onFrame(frame) }
            }
        case .microphone:
            let node = audioEngine.inputNode
            // Noise suppression and gain from iOS, when chosen. Set before the format is read.
            try? node.setVoiceProcessingEnabled(SpeechSettings.voiceProcessing)
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Muisti.Speech", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "The microphone isn't ready. Try again.")])
            }
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                onSamples(resampler.convert(buffer))
                if let frame = spectrum.process(buffer) { onFrame(frame) }
            }
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    func stop() {
        switch source {
        case .glasses(let tap): tap.setConsumer(nil)
        case .microphone:
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }
}

/// A spoken question through Parakeet, on the phone. The whole utterance so far is read
/// again a few times a second (the model reads ten seconds of audio in a fraction of one),
/// so the text on screen is corrected as more is heard, and the final text is one more read
/// of everything. When to stop comes from the speech/no-speech model, not from loudness.
final class ParakeetSpeechSession: ListeningSession, @unchecked Sendable {
    private let capture: MicCapture
    private struct State {
        var samples: [Float] = []
        var text = ""
        var readUpTo = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var partials: Task<Void, Never>?
    private var gate: VoiceGate?

    /// Longest question kept (the listener gives up after 25 s anyway).
    private static let maxSamples = 16_000 * 30
    /// New audio needed before the text is read again.
    private static let rereadAfter = 16_000 * 4 / 10

    private let localeIdentifier: String

    init(source: MicSource, localeIdentifier: String) {
        capture = MicCapture(source: source)
        self.localeIdentifier = localeIdentifier
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws {
        let state = state
        let locale = localeIdentifier
        // While speech is heard, the current text is repeated: the listener's end-of-question
        // timer restarts on every update, so it runs out only after real silence.
        let lastBeat = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let gate = VoiceGate {
            let now = Date()
            guard lastBeat.withLock({ last in
                guard now.timeIntervalSince(last) > 0.2 else { return false }
                last = now
                return true
            }) else { return }
            onText(state.withLock { $0.text }, false)
        }
        self.gate = gate
        try capture.start(onSamples: { samples in
            state.withLock { s in
                guard s.samples.count < Self.maxSamples else { return }
                s.samples += samples
            }
            gate.feed(samples)
        }, onFrame: onFrame)
        partials = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let pending = state.withLock { s -> [Float]? in
                    guard s.samples.count - s.readUpTo >= Self.rereadAfter, s.samples.count >= 8_000 else { return nil }
                    s.readUpTo = s.samples.count
                    return s.samples
                }
                // Nothing that sounds like speech yet: no reading (the model would only guess at noise).
                guard let pending, !Task.isCancelled, gate.voicedSeconds >= 0.25 || !gate.usedNeural else { continue }
                // Only up to where the user's own voice ends: what follows is the room
                // (other people, a television) and is not part of the question.
                let own = Self.trimmed(pending, gate: gate)
                guard let text = await SpeechLab.shared.transcribe(own, localeIdentifier: locale), !Task.isCancelled else { continue }
                let changed = state.withLock { s -> Bool in
                    guard s.text != text else { return false }
                    s.text = text
                    return true
                }
                if changed { onText(text, false) }
            }
        }
    }

    func finalize(timeout: Double) async -> String? {
        capture.stop()
        partials?.cancel()
        var (samples, last) = state.withLock { ($0.samples, $0.text) }
        if let gate, gate.usedNeural, gate.voicedSeconds < 0.25 { return last.isEmpty ? nil : last }
        if let gate { samples = Self.trimmed(samples, gate: gate) }
        // One read of everything. Usually a few hundred ms; the last partial stands if it takes longer.
        let locale = localeIdentifier
        let lab = Task { await SpeechLab.shared.transcribe(samples, localeIdentifier: locale) }
        let limit = Task { try? await Task.sleep(for: .seconds(max(timeout, 2.5))); lab.cancel() }
        let final = await lab.value
        limit.cancel()
        if let final, !final.isEmpty { return final }
        return last.isEmpty ? nil : last
    }

    func stop() {
        capture.stop()
        partials?.cancel()
        partials = nil
    }

    /// The recording up to half a second past the user's last own speech.
    private static func trimmed(_ samples: [Float], gate: VoiceGate) -> [Float] {
        guard gate.usedNeural else { return samples }
        let end = gate.userSpeechEnd + 8_000
        return end < samples.count ? Array(samples[..<end]) : samples
    }
}

/// One recording through Apple's on-device recognisers, for the microphone test.
enum AppleSpeechTest {
    /// `SpeechAnalyzer` (iOS 26+): the general model or the dictation model.
    static func modern(_ samples: [Float], localeIdentifier: String, dictation: Bool) async -> String? {
        guard #available(iOS 26, *), let prepared = await AnalyzerSpeech.prepared(localeIdentifier),
              let buffer = Resampler16k.buffer(samples) else { return nil }
        return await analyze(buffer, prepared: prepared, dictation: dictation)
    }

    @available(iOS 26, *)
    private static func analyze(_ buffer: AVAudioPCMBuffer, prepared: AnalyzerSpeech.Prepared, dictation: Bool) async -> String? {
        let converter = AVAudioConverter(from: buffer.format, to: prepared.format)
        var input = buffer
        if buffer.format != prepared.format, let converter,
           let out = AVAudioPCMBuffer(pcmFormat: prepared.format,
                                      frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * prepared.format.sampleRate / buffer.format.sampleRate + 64)) {
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { input = out }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collected = OSAllocatedUnfairLock(initialState: "")
        let reading: Task<Void, Never>
        let analyzer: SpeechAnalyzer
        if dictation {
            let module = AnalyzerSpeech.makeDictation(prepared.locale)
            analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module])
            reading = Task {
                do { for try await result in module.results where result.isFinal { collected.withLock { $0 += " " + String(result.text.characters) } } } catch {}
            }
        } else {
            let module = AnalyzerSpeech.makeTranscriber(prepared.locale)
            analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module])
            reading = Task {
                do { for try await result in module.results where result.isFinal { collected.withLock { $0 += " " + String(result.text.characters) } } } catch {}
            }
        }
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let limit = Task { try? await Task.sleep(for: .seconds(8)); reading.cancel() }
        await reading.value
        limit.cancel()
        return collected.withLock { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// `SFSpeechRecognizer`, on the device only (what Muisti falls back to when the newer
    /// model is not installed for the language).
    static func legacy(_ samples: [Float], localeIdentifier: String) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition, let buffer = Resampler16k.buffer(samples) else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()
        let final = FinalTranscript()
        let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result, result.isFinal { final.deliver(result.bestTranscription.formattedString) } else if error != nil { final.deliver(nil) }
        }
        let text = await final.wait(timeout: 10)
        task.finish()
        return text
    }
}
