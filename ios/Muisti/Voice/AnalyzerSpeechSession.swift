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
        let dictation = AnalyzerSpeech.makeDictation(prepared.locale)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber, dictation], analysisContext: context)

        // Two hearings of the same audio. While speaking the user sees the general model's text;
        // at the end the dictation text wins if it caught more of the names in memory.
        let speechText = text, dictationText = OSAllocatedUnfairLock(initialState: (finalized: "", volatile: ""))
        let final = final, vocabulary = contextualStrings
        let ended = OSAllocatedUnfairLock(initialState: 0)
        @Sendable func finished() {
            guard ended.withLock({ $0 += 1; return $0 }) == 2 else { return }
            let general = speechText.withLock { Self.join($0.finalized, $0.volatile) }
            let dictated = dictationText.withLock { Self.join($0.finalized, $0.volatile) }
            let pick = Self.namesCaught(in: dictated, vocabulary) > Self.namesCaught(in: general, vocabulary) ? dictated : general
            if pick == dictated, pick != general { Log.pipeline.info("speech: dictation hearing kept (names from memory)") }
            final.deliver(pick.isEmpty ? nil : pick)
        }
        @Sendable func take(_ state: OSAllocatedUnfairLock<(finalized: String, volatile: String)>, _ piece: String, _ isFinal: Bool) -> String {
            state.withLock { t -> String in
                if isFinal {
                    t.finalized = Self.join(t.finalized, piece)
                    t.volatile = ""
                } else {
                    t.volatile = piece
                }
                return Self.join(t.finalized, t.volatile)
            }
        }
        resultsTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await result in transcriber.results {
                            onText(take(speechText, String(result.text.characters), result.isFinal), false)
                        }
                    } catch {
                        if !Task.isCancelled { onError(error.localizedDescription) }
                    }
                    finished()
                }
                group.addTask {
                    do {
                        for try await result in dictation.results {
                            _ = take(dictationText, String(result.text.characters), result.isFinal)
                        }
                    } catch {}
                    finished()
                }
            }
        }

        let feeder = Feeder(target: prepared.format, continuation: continuation)
        let analyzer = SpectrumAnalyzer()
        // While the user is audibly speaking, repeat the current text: the listener restarts
        // its end-of-question timer on every update, so it only ends after real silence, not
        // when the model goes quiet for a few seconds before finalising a phrase.
        let activity = VoiceActivity()
        let lastBeat = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let heartbeat: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            guard activity.isVoice(buffer) else { return }
            let now = Date()
            guard lastBeat.withLock({ last in
                guard now.timeIntervalSince(last) > 0.25 else { return false }
                last = now
                return true
            }) else { return }
            // Before the first words this is an empty update: the listener then keeps waiting
            // for words (they come about a second after the voice), never ends early.
            onText(speechText.withLock { Self.join($0.finalized, $0.volatile) }, false)
        }
        switch source {
        case .glasses(let tap):
            tap.setConsumer { buffer in
                feeder.feed(buffer)
                heartbeat(buffer)
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
                heartbeat(buffer)
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

    /// How many of the names in memory a hearing contains (case and accents ignored).
    private static func namesCaught(in text: String, _ names: [String]) -> Int {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "’", with: "'")
        }
        let heard = fold(text)
        return names.filter { $0.count >= 3 && heard.contains(fold($0)) }.count
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
