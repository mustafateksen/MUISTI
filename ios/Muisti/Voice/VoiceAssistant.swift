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
        if phase == .listening { await finishListening() } else { await startListening() }
    }

    func startListening() async {
        guard phase != .listening, phase != .thinking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        transcript = ""

        guard await Self.requestSpeechAuthorization() else {
            phase = .failed("Konuşma tanıma izni yok. Ayarlar > Muisti > Konuşma Tanıma.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Mikrofon izni yok. Ayarlar > Muisti > Mikrofon.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            phase = .failed("Bu dil için konuşma tanıma şu an kullanılamıyor (\(localeIdentifier)).")
            return
        }
        do {
            try Self.activateAudioSession()
            let session = SpeechSession(recognizer: recognizer)
            let levels = levels
            try session.start { [weak self] text, isFinal in
                Task { @MainActor in self?.handlePartial(text, isFinal: isFinal) }
            } onError: { [weak self] message in
                Task { @MainActor in self?.handleError(message) }
            } onBands: { bands in
                Task { @MainActor in levels.update(bands) }
            }
            self.session = session
            phase = .listening
            armSilenceTimer(after: 6)   // nothing said within 6 s → give up quietly
            maxTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.finishListening()
            }
        } catch {
            phase = .failed("Mikrofon açılamadı: \(error.localizedDescription)")
            Self.deactivateAudioSession()
        }
    }

    func finishListening() async {
        guard phase == .listening else { return }
        silenceTask?.cancel()
        maxTask?.cancel()
        session?.stop()
        session = nil
        levels.reset()
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .idle
            Self.deactivateAudioSession()
            return
        }
        await ask(question)
    }

    /// Typed question (also used by tests and when speech is unavailable).
    func ask(_ question: String) async {
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
    }

    private func handlePartial(_ text: String, isFinal: Bool) {
        guard phase == .listening else { return }
        transcript = text
        if isFinal {
            Task { await finishListening() }
        } else {
            armSilenceTimer(after: 1.6)   // end of question = 1.6 s without new words
        }
    }

    private func handleError(_ message: String) {
        guard phase == .listening else { return }
        if transcript.isEmpty {
            session?.stop()
            session = nil
            levels.reset()
            phase = .failed(message)
            Self.deactivateAudioSession()
        } else {
            Task { await finishListening() }
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
               onError: @escaping @Sendable (String) -> Void,
               onBands: @escaping @Sendable ([Float]) -> Void) throws {
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
                onError(error.localizedDescription)
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
