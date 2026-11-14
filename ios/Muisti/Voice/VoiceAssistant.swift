@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Push-to-talk (or "Hey Siri, Muisti'ye sor") → glasses mic over Bluetooth HFP →
/// on-device speech recognition → `QueryEngine` → spoken answer on the glasses speakers.
@Observable
@MainActor
final class VoiceAssistant {
    enum Phase: Equatable {
        case idle, listening, thinking, speaking
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var lastResult: AskResult?
    private(set) var history: [AskResult] = []
    var localeIdentifier = "en-US"
    private(set) var handsFree = false
    private(set) var waitingForWake = false
    private(set) var openingMic = false
    private var generation = 0
    private var triggeredByPhrase = false
    var speakAnswers = true
    /// Microphone spectrum and spoken-word pulses for the visualizer.
    let levels = VoiceLevels()

    @ObservationIgnored private let engine: QueryEngine
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private var session: SpeechSession?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var speechDelegate: SpeechFinishDelegate?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var maxTask: Task<Void, Never>?

    init(engine: QueryEngine, location: LocationProvider) {
        self.engine = engine
        self.location = location
    }

    var isBusy: Bool { phase == .listening || phase == .thinking || phase == .speaking }

    // MARK: Listen

    func toggleListening() async {
        if phase == .listening && !waitingForWake { await finishListening() } else { await startListening() }
    }

    func startListening() async {
        if waitingForWake {
            stopMic()
            await openMic(waitForWake: false)
        } else if phase != .listening && phase != .thinking && phase != .speaking {
            await openMic(waitForWake: false)
        }
    }

    func setHandsFree(_ enabled: Bool) async {
        guard enabled != handsFree else { return }
        handsFree = enabled
        if !enabled {
            if openingMic || phase == .listening {
                stopMic()
                phase = .idle
                Self.deactivateAudioSession()
            }
        } else if !isBusy {
            await openMic(waitForWake: true)
        }
    }

    private func stopMic() {
        generation += 1
        openingMic = false
        waitingForWake = false
        triggeredByPhrase = false
        silenceTask?.cancel()
        maxTask?.cancel()
        session?.stop()
        session = nil
        levels.reset()
    }

    private func micFailure(_ message: String) {
        stopMic()
        handsFree = false
        phase = .failed(message)
        Self.deactivateAudioSession()
    }

    private func openMic(waitForWake: Bool) async {
        guard !openingMic, session == nil else { return }
        generation += 1
        let ticket = generation
        openingMic = true
        transcript = ""
        let speechAllowed = await Self.requestSpeechAuthorization()
        guard ticket == generation else { return }
        guard speechAllowed else { micFailure("Konuşma tanıma izni gerekiyor."); return }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard ticket == generation else { return }
        guard micAllowed else { micFailure("Mikrofon izni gerekiyor."); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            micFailure("Konuşma tanıma kullanılamıyor (\(localeIdentifier)).")
            return
        }
        if handsFree && !recognizer.supportsOnDeviceRecognition {
            micFailure("Hey Emir için bu dilde cihaz üstü konuşma tanıma gerekiyor.")
            return
        }
        do {
            try Self.activateAudioSession()
            let session = SpeechSession(recognizer: recognizer)
            self.session = session
            try session.start { [weak self] text, final in
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    await self.handlePartial(text, isFinal: final)
                }
            } onError: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    if self.waitingForWake && error.domain == "kAFAssistantErrorDomain" && error.code == 1110 {
                        await self.finishListening()
                    } else if self.transcript.isEmpty {
                        self.micFailure(error.localizedDescription)
                    } else {
                        await self.finishListening()
                    }
                }
            } onBands: { [weak self] bands in
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    self.levels.update(bands)
                }
            }
            openingMic = false
            waitingForWake = waitForWake
            phase = .listening
            if !waitForWake { armSilenceTimer(after: 6) }
            armLimit(waitForWake ? 45 : 15)
        } catch {
            micFailure("Mikrofon açılamadı: \(error.localizedDescription)")
        }
    }

    private func armLimit(_ seconds: Double) {
        maxTask?.cancel()
        maxTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.finishListening()
        }
    }

    func finishListening() async {
        guard phase == .listening else { return }
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopMic()
        phase = .idle
        if !question.isEmpty {
            await ask(question)
        } else if handsFree {
            await openMic(waitForWake: true)
        } else {
            Self.deactivateAudioSession()
        }
    }

    /// Typed question (also used by tests and when speech is unavailable).
    func ask(_ question: String) async {
        guard !openingMic, phase != .thinking, phase != .speaking else { return }
        stopMic()
        transcript = question
        phase = .thinking
        let result = await engine.ask(question, location: location.freshFix(maxAge: 120))
        Log.pipeline.info("ask “\(question, privacy: .public)” → [\(result.label.rawValue, privacy: .public)] \(result.answer, privacy: .public) · evidence \(result.evidence.map(\.record.id), privacy: .public) · \(result.latencyMs) ms · ai \(result.usedAI) · note \(result.note ?? "-", privacy: .public) · \(result.trace ?? "", privacy: .public)")
        lastResult = result
        history.insert(result, at: 0)
        if history.count > 20 { history.removeLast() }
        if speakAnswers {
            phase = .speaking
            await speak(result.answer, language: result.language ?? localeIdentifier)
        }
        phase = .idle
        Self.deactivateAudioSession()
        if handsFree { await openMic(waitForWake: true) }
    }

    // A recognition partial is cumulative. Extract the suffix on each revision.
    static func wakeSuffix(_ text: String) -> String? {
        guard let range = text.range(of: #"(?i)\bhey[\s,!.?-]+emir\b"#,
                                     options: .regularExpression, range: nil, locale: nil) else { return nil }
        return String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func handlePartial(_ text: String, isFinal: Bool) async {
        guard phase == .listening else { return }
        if waitingForWake {
            guard let suffix = Self.wakeSuffix(text) else {
                if isFinal { await finishListening() }
                return
            }
            waitingForWake = false
            triggeredByPhrase = true
            armLimit(15)
            transcript = suffix
        } else if triggeredByPhrase {
            if let suffix = Self.wakeSuffix(text) { transcript = suffix }
        } else {
            transcript = text
        }
        if isFinal && triggeredByPhrase && transcript.isEmpty {
            // Some recognizers finalize just the wake words during a short pause.
            stopMic()
            await openMic(waitForWake: false)
        } else if isFinal {
            await finishListening()
        } else {
            armSilenceTimer(after: transcript.isEmpty ? 6 : 1.6)
        }
    }

    private func armSilenceTimer(after seconds: Double) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.finishListening()
        }
    }

    // MARK: Speak

    private func speak(_ text: String, language: String) async {
        // Answer in A2DP quality: drop the hands-free (mic) route while speaking.
        try? Self.activatePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        // `language` is a BCP-47 tag or a bare ISO 639-1 code from Nemotron ("tr", "fi").
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(language + "-") }
            ?? AVSpeechSynthesisVoice(language: localeIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let levels = levels
            let delegate = SpeechFinishDelegate {
                Task { @MainActor in levels.wordSpoken() }
            } done: { @Sendable in
                done.resume()
            }
            speechDelegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
        speechDelegate = nil
    }

    // MARK: Audio session

    /// Glasses appear as a Bluetooth headset: HFP gives the glasses mic, A2DP/HFP the speakers.
    static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let bluetooth: AVAudioSession.CategoryOptions
        if #available(iOS 26.0, *) {
            bluetooth = .allowBluetoothHFP
        } else {
            bluetooth = AVAudioSession.CategoryOptions(rawValue: 0x4)   // .allowBluetooth
        }
        try session.setCategory(.playAndRecord, mode: .default, options: [bluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        // Prefer a Bluetooth input (the glasses) when one is connected.
        if let bt = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(bt)
        }
    }

    static func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    /// Hands the route back (camera transfers share the Bluetooth link with HFP).
    static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// `nonisolated` + `@Sendable`: TCC calls this back on a background queue. A main-actor
    /// closure here trapped at runtime (Swift 6 isolation check) — the voice-button crash.
    nonisolated static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    done.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }
}

/// AVAudioEngine + recognition task. Callbacks arrive on audio / recognizer threads.
private final class SpeechSession: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (NSError) -> Void,
               onBands: @escaping @Sendable ([Float]) -> Void) throws {
        request.contextualStrings = ["Hey Emir"]
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // the question never leaves the phone
        }
        request.taskHint = .search
        let input = audioEngine.inputNode
        // The route may just have switched to the glasses (HFP, 8/16 kHz). Installing a tap with
        // a stale or empty format raises an Objective-C exception that kills the app.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Muisti.Speech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon hazır değil; tekrar dene."])
        }
        let request = request
        let analyzer = SpectrumAnalyzer()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            request.append(buffer)
            if let bands = analyzer.bands(for: buffer) { onBands(bands) }
        }
        audioEngine.prepare()
        try audioEngine.start()
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result {
                onText(result.bestTranscription.formattedString, result.isFinal)
            } else if let error {
                onError(error as NSError)
            }
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request.endAudio()
        task?.finish()
        task = nil
    }
}

private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var done: (@Sendable () -> Void)?
    private let onWord: @Sendable () -> Void

    init(onWord: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        self.onWord = onWord
        self.done = done
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        onWord()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { fire() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { fire() }

    /// Called on the synthesizer's queue; resumes exactly once.
    private func fire() {
        lock.lock()
        let callback = done
        done = nil
        lock.unlock()
        callback?()
    }
}
