@preconcurrency import AVFoundation
import os
import Speech

/// A spoken question through `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+), from the iPhone
/// microphone or the glasses mic in the camera stream. Same contract as the
/// `SFSpeechRecognizer` sessions: partial text while speaking, `finalize` for the final text.
@available(iOS 26, *)
final class AnalyzerSpeechSession: ListeningSession, @unchecked Sendable {
    enum Source {
        case microphone
        case glasses(GlassesMicTap)
    }

    private let prepared: AnalyzerSpeech.Prepared
    private let source: Source
    private let contextualStrings: [String]
    private let audioEngine = AVAudioEngine()
    private let final = FinalTranscript()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Finalised text so far + the newest volatile guess for what follows it.
    private let text = OSAllocatedUnfairLock(initialState: (finalized: "", volatile: ""))

    init(prepared: AnalyzerSpeech.Prepared, source: Source, contextualStrings: [String]) {
        self.prepared = prepared
        self.source = source
        self.contextualStrings = contextualStrings
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws {
        let transcriber = AnalyzerSpeech.makeTranscriber(prepared.locale)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)

        let text = text, final = final
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    let full = text.withLock { t -> String in
                        if result.isFinal {
                            t.finalized = Self.join(t.finalized, piece)
                            t.volatile = ""
                        } else {
                            t.volatile = piece
                        }
                        return Self.join(t.finalized, t.volatile)
                    }
                    onText(full, false)
                }
                final.deliver(text.withLock { Self.join($0.finalized, $0.volatile) })
            } catch {
                final.deliver(nil)
                if !Task.isCancelled { onError(error.localizedDescription) }
            }
        }

        let feeder = Feeder(target: prepared.format, continuation: continuation)
        let analyzer = SpectrumAnalyzer()
        switch source {
        case .glasses(let tap):
            tap.setConsumer { buffer in
                feeder.feed(buffer)
                if let frame = analyzer.process(buffer) { onFrame(frame) }
            }
        case .microphone:
            let node = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Muisti.Speech", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "The microphone isn't ready. Try again.")])
            }
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                feeder.feed(buffer)
                if let frame = analyzer.process(buffer) { onFrame(frame) }
            }
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    func finalize(timeout: Double) async -> String? {
        stopAudio()
        input?.finish()
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        return await final.wait(timeout: timeout)
    }

    func stop() {
        stopAudio()
        input?.finish()
        input = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func stopAudio() {
        switch source {
        case .glasses(let tap): tap.setConsumer(nil)
        case .microphone:
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// Converts whatever the microphone delivers (48 kHz float, 16 kHz glasses PCM…) to the
/// model's format and hands it to the analyzer. Called on the audio thread.
@available(iOS 26, *)
private final class Feeder: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return }
        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
}
