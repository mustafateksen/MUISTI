@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

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
    var localeIdentifier = "tr-TR"
    var speakAnswers = true

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
            try session.start { [weak self] text, isFinal in
                Task { @MainActor in self?.handlePartial(text, isFinal: isFinal) }
            } onError: { [weak self] message in
                Task { @MainActor in self?.handleError(message) }
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
        Log.pipeline.info("ask “\(question, privacy: .public)” → [\(result.label.rawValue, privacy: .public)] \(result.answer, privacy: .public) · evidence \(result.evidence.map(\.record.id), privacy: .public) · \(result.latencyMs) ms · ai \(result.usedAI) · note \(result.note ?? "-", privacy: .public)")
        lastResult = result
        history.insert(result, at: 0)
        if history.count > 20 { history.removeLast() }
        if speakAnswers {
            phase = .speaking
            await speak(result.answer, language: result.answer.range(of: "[çğıöşüÇĞİÖŞÜ]", options: .regularExpression) != nil ? "tr-TR" : localeIdentifier)
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
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let delegate = SpeechFinishDelegate { done.resume() }
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

    static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { done in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
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

    func start(onText: @escaping @Sendable (String, Bool) -> Void, onError: @escaping @Sendable (String) -> Void) throws {
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // the question never leaves the phone
        }
        request.taskHint = .search
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        task = recognizer.recognitionTask(with: request) { result, error in
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
    private var done: (() -> Void)?

    init(done: @escaping () -> Void) { self.done = done }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { fire() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { fire() }

    private func fire() {
        done?()
        done = nil
    }
}
