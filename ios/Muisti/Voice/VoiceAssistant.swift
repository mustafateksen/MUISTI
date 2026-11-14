import UIKit
@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Push-to-talk (or "Hey Siri, ask Muisti") → glasses mic over Bluetooth HFP →
/// on-device speech recognition → `QueryEngine` → spoken answer on the glasses speakers.
@Observable
@MainActor
final class VoiceAssistant {
    enum Phase: Equatable {
        case idle, listening, thinking, speaking
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var lastResult: AskResult?
    private(set) var history: [AskResult] = []
    var localeIdentifier = "en-US"
    var speakAnswers = true
    /// Whether listening may use the glasses mic (HFP). Set by the controller: false while the
    /// glasses camera is streaming.
    @ObservationIgnored var prefersGlassesMic: () -> Bool = { true }
    /// Microphone spectrum and spoken-word pulses for the visualizer.
    let levels = VoiceLevels()
    /// Runs a Muisti Turva command from a reply; may return a reply to say instead.
    @ObservationIgnored var safetyHandler: (SafetyCommand) async -> String? = { _ in nil }
    /// Hands-free: the glasses listen for the wake word; a question Muisti asks is answered
    /// there instead of opening the phone mic.
    @ObservationIgnored var glassesListening: () -> Bool = { false }
    @ObservationIgnored var expectGlassesReply: () -> Void = {}
    /// Names the recogniser should expect (from memory and the safety rules).
    @ObservationIgnored var vocabulary: () async -> [String] = { [] }

    @ObservationIgnored private let engine: QueryEngine
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private var session: ListeningSession?
    /// The glasses mic carried in the camera stream (preferred: works with the phone locked,
    /// no Bluetooth profile switch).
    @ObservationIgnored var glassesMic: GlassesMicTap?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player = SpeechPlayer()
    @ObservationIgnored private var speechDelegate: SpeechFinishDelegate?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var maxTask: Task<Void, Never>?
    /// Starts the search on what was heard so far, shortly into a pause (see `QueryEngine.prepare`).
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    /// The question being answered (cancelled when the user taps to say something else).
    @ObservationIgnored private var queryTask: Task<AskResult, Never>?
    /// The user tapped while Muisti was thinking or speaking: drop that turn and listen.
    @ObservationIgnored private var interrupted = false
    /// Warnings that arrived while a question was being heard or answered: said right after it.
    @ObservationIgnored private var waitingAnnouncements: [(text: String, language: String?, expectsReply: Bool)] = []
    @ObservationIgnored private var recognizers: [String: SFSpeechRecognizer] = [:]
    @ObservationIgnored private var knownNames: [String] = []
    @ObservationIgnored private var knownNamesAt = Date.distantPast
    /// Times of one spoken turn, written to the trace file when it ends.
    @ObservationIgnored private var turn = TurnTimeline()

    /// End of a question = this long without a new word. The search already starts
    /// `prepareAfter` into the pause, so the wait is not lost time.
    static let endOfQuestionSilence = 1.2
    static let prepareAfter = 0.45

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
        player.stop()
        transcript = ""

        guard await Self.requestSpeechAuthorization() else {
            phase = .failed("No access to Speech Recognition. Settings > Muisti > Speech Recognition.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("No access to the microphone. Settings > Muisti > Microphone.")
            return
        }
        guard let recognizer = recognizer(), recognizer.isAvailable else {
            phase = .failed("Speech recognition isn't available for this language right now (\(localeIdentifier)).")
            return
        }
        do {
            let levels = levels
            let session: ListeningSession
            let names = await names()
            if let tap = glassesMic, tap.isFlowing {
                Log.pipeline.info("listening on the glasses mic (camera stream audio)")
                session = TapSpeechSession(recognizer: recognizer, contextualStrings: names, tap: tap)
            } else {
                try Self.activateAudioSession(glassesMic: prefersGlassesMic())
                session = SpeechSession(recognizer: recognizer, contextualStrings: names)
            }
            try session.start { [weak self] text, isFinal in
                Task { @MainActor in self?.handlePartial(text, isFinal: isFinal) }
            } onError: { [weak self] message in
                Task { @MainActor in self?.handleError(message) }
            } onFrame: { frame in
                Task { @MainActor in levels.update(frame) }
            }
            self.session = session
            phase = .listening
            turn.mark("mic open")
            armSilenceTimer(after: 6)   // nothing said within 6 s → give up quietly
            maxTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.finishListening()
            }
        } catch {
            Log.glasses.info("microphone failed (\(UIApplication.shared.applicationState == .active ? "foreground" : "background", privacy: .public)): \(error.localizedDescription, privacy: .public)")
            phase = .failed(UIApplication.shared.applicationState == .active
                            ? "Couldn't turn on the microphone: \(error.localizedDescription)"
                            : "Couldn't turn on the microphone while the phone is locked. Start recording with the glasses, then try again.")
            playEndTone()
            Self.deactivateAudioSession()
        }
    }

    func finishListening() async {
        guard phase == .listening else { return }
        silenceTask?.cancel()
        maxTask?.cancel()
        prepareTask?.cancel()
        turn.mark("end of question")
        session?.stop()
        session = nil
        levels.reset()
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .idle
            playEndTone()   // listening is over (nothing said)
            await engine.dropPrepared()
            try? await Task.sleep(for: .milliseconds(700))
            Self.deactivateAudioSession()
            await sayWaitingAnnouncements()
            return
        }
        // Leave .listening now, before any suspension: the recogniser's final result and the
        // silence timer both end a question, and only the first may ask it.
        phase = .thinking
        playEndTone()   // listening is over: the question is on its way
        // We usually get here from the silence/max timer task, which was just cancelled above:
        // asking inside it would cancel every Nemotron request at once (instant local-search
        // answer). A fresh task does not inherit that cancellation.
        await Task { await self.ask(question, byVoice: true) }.value
    }

    /// Stops listening without asking, or stops reading the answer aloud.
    func cancel() {
        switch phase {
        case .listening:
            silenceTask?.cancel()
            maxTask?.cancel()
            prepareTask?.cancel()
            Task { await engine.dropPrepared() }
            session?.stop()
            session = nil
            levels.reset()
            transcript = ""
            phase = .idle
            Self.deactivateAudioSession()
        case .thinking:
            // The question is dropped: its answer is neither shown nor spoken.
            interrupted = true
            queryTask?.cancel()
        case .speaking:
            player.stop()
            synthesizer.stopSpeaking(at: .immediate)
        default:
            break
        }
    }

    /// Starts a new conversation on screen (stored memories are untouched).
    func clearConversation() {
        guard !isBusy else { return }
        Task { await engine.clearConversation() }
        history = []
        lastResult = nil
        transcript = ""
        phase = .idle
    }

    /// A question heard through the glasses (wake word already removed).
    func askFromGlasses(_ question: String) async {
        guard !isBusy else { return }
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        await ask(question, byVoice: true)
    }

    /// Typed question (also used by tests and when speech is unavailable).
    func ask(_ question: String, byVoice: Bool = false) async {
        transcript = question
        phase = .thinking
        interrupted = false
        turn.mark("asking")
        let engine = engine, fix = location.freshFix(maxAge: 120)
        let query = Task { await engine.ask(question, location: fix) }
        queryTask = query
        let waiting = byVoice ? waitingTones() : nil
        var result = await query.value
        waiting?.cancel()
        queryTask = nil
        if interrupted {
            // The user tapped to say something else: this answer is not shown or spoken.
            Log.pipeline.info("ask “\(question, privacy: .public)” dropped (the user interrupted)")
            interrupted = false
            phase = .idle
            return
        }
        turn.mark("answer ready")
        if let command = result.safety, let reply = await safetyHandler(command) {
            result.answer = reply
            await engine.noteExchange(question: question, answer: reply)
        }
        Log.pipeline.info("ask “\(question, privacy: .public)” → [\(result.label.rawValue, privacy: .public)] \(result.answer, privacy: .public) · evidence \(result.evidence.map(\.record.id), privacy: .public) · \(result.latencyMs) ms · ai \(result.usedAI) · note \(result.note ?? "-", privacy: .public) · \(result.trace ?? "", privacy: .public)")
        lastResult = result
        history.insert(result, at: 0)
        if history.count > 20 { history.removeLast() }
        if speakAnswers {
            phase = .speaking
            await speak(result.answer, language: result.language ?? localeIdentifier)
        }
        turn.mark("spoken")
        Trace.note("turn “\(question.prefix(60))” · \(turn.summary) · engine \(result.latencyMs) ms · \(result.trace ?? "")")
        phase = .idle
        if interrupted {
            // Stopped by a tap: the microphone opens next (`pushToTalk`), nothing else happens.
            interrupted = false
            return
        }
        Self.deactivateAudioSession()
        if await sayWaitingAnnouncements() { return }
        // Spoken conversation: the mic opens again (earcon first) only when Muisti asked
        // something back (`expects_reply`); after "thanks" or a plain answer it stays closed,
        // and a double tap asks the next question.
        if byVoice, speakAnswers, !result.spontaneous, result.expectsReply {
            if glassesListening() { expectGlassesReply() } else { await listenWithEarcon() }
        }
    }

    /// Muisti speaks first: a safety warning or a yes/no question. Shown in the chat too; a
    /// question opens the microphone for the answer.
    func announce(_ text: String, language: String?, expectsReply: Bool, frame: URL? = nil) async {
        let note = AskResult(question: expectsReply ? "Muisti asks" : "Safety warning", answer: text, label: .seen,
                             evidence: [], usedAI: false, latencyMs: 0, note: nil, language: language,
                             isCommand: true, safetyFrames: frame.map { [$0] } ?? [], spontaneous: true)
        lastResult = note
        history.insert(note, at: 0)
        if history.count > 20 { history.removeLast() }
        await engine.noteMuistiSaid(text)
        // Never talk over the user or over an answer being read: it is said right after.
        // (Before, a warning that arrived during a question was only written to the history.)
        guard phase == .idle || phase.isFailed else {
            waitingAnnouncements.append((text, language, expectsReply))
            if waitingAnnouncements.count > 3 { waitingAnnouncements.removeFirst() }
            Trace.note("warning held until the turn ends: \(text.prefix(60))")
            return
        }
        await say(text, language: language, expectsReply: expectsReply)
    }

    private func say(_ text: String, language: String?, expectsReply: Bool) async {
        phase = .speaking
        await speak(text, language: language ?? localeIdentifier)
        phase = .idle
        Self.deactivateAudioSession()
        if interrupted {
            interrupted = false
            return
        }
        if expectsReply {
            if glassesListening() { expectGlassesReply() } else { await startListening() }
        }
    }

    /// Says the warnings held back during the last turn. Returns whether anything was said.
    @discardableResult
    private func sayWaitingAnnouncements() async -> Bool {
        guard !waitingAnnouncements.isEmpty else { return false }
        while phase == .idle || phase.isFailed, !waitingAnnouncements.isEmpty {
            let next = waitingAnnouncements.removeFirst()
            await say(next.text, language: next.language, expectsReply: next.expectsReply)
        }
        return true
    }

    /// A quiet tick while the answer is being worked out, so a slow reply is not dead air.
    private func waitingTones() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            while !Task.isCancelled, let self, self.phase == .thinking {
                self.playWaitingTone()
                try? await Task.sleep(for: .seconds(2.4))
            }
        }
    }

    private func recognizer() -> SFSpeechRecognizer? {
        if let known = recognizers[localeIdentifier] { return known }
        let made = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        recognizers[localeIdentifier] = made
        return made
    }

    /// Names for the recogniser. Read from memory at most once a minute (a scan of the newest
    /// records): a stale list is used at once and refreshed behind it.
    private func names() async -> [String] {
        if knownNames.isEmpty {
            knownNames = await vocabulary()
            knownNamesAt = Date()
        } else if Date().timeIntervalSince(knownNamesAt) > 60 {
            knownNamesAt = Date()
            Task { self.knownNames = await self.vocabulary() }
        }
        return knownNames
    }

    /// Before the first question: the recogniser and the name list are ready when the tap comes.
    func warmUp() {
        _ = recognizer()
        Task { _ = await self.names() }
    }

    private func handlePartial(_ text: String, isFinal: Bool) {
        guard phase == .listening else { return }
        let changed = text != transcript
        transcript = text
        if isFinal {
            Task { await finishListening() }
        } else {
            if changed { turn.mark("last word") }
            armSilenceTimer(after: Self.endOfQuestionSilence)
            // A short pause: start searching on these words. If the user goes on, the next
            // partial replaces it; if not, the answer is that much closer when listening ends.
            prepareTask?.cancel()
            prepareTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.prepareAfter))
                guard !Task.isCancelled, let self, self.phase == .listening else { return }
                await self.engine.prepare(text, location: self.location.freshFix(maxAge: 120))
            }
        }
    }

    private func handleError(_ message: String) {
        guard phase == .listening else { return }
        if transcript.isEmpty {
            // Usually "no speech": listening simply ends, with its closing tone.
            Log.pipeline.info("listening ended without speech: \(message, privacy: .public)")
            silenceTask?.cancel()
            maxTask?.cancel()
            prepareTask?.cancel()
            session?.stop()
            session = nil
            levels.reset()
            phase = .idle
            playEndTone()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if self.phase == .idle {
                    Self.deactivateAudioSession()
                    await self.sayWaitingAnnouncements()
                }
            }
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

    /// Settings: hear the chosen voice.
    func previewVoice(language: String) async {
        guard phase == .idle || phase.isFailed else { return }
        let sample = VoicePicker.languageCode(language) == "tr"
            ? "Merhaba, ben Muisti. Gördüklerini hatırlarım."
            : "Hi, I'm Muisti. I remember what you see, so you don't have to."
        await speak(sample, language: language)
        Self.deactivateAudioSession()
    }

    private func speak(_ text: String, language: String) async {
        // Answer in A2DP quality: drop the hands-free (mic) route while speaking.
        try? Self.activatePlaybackSession()
        await Self.waitForHighQualityOutput()
        let utterance = AVSpeechUtterance(string: text)
        // `language` is a BCP-47 tag or a bare ISO 639-1 code from Nemotron ("tr", "fi").
        if let chosen = VoicePicker.chosenVoice(for: language) {
            // A voice picked in Muisti's settings.
            utterance.voice = chosen
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.prefersAssistiveTechnologySettings = false
        } else {
            // Default: exactly the voice, rate and pitch set for Spoken Content in the iPhone's
            // Accessibility settings (the language hint picks that language's voice there).
            utterance.voice = AVSpeechSynthesisVoice(language: language) ?? VoicePicker.voice(for: language, fallback: localeIdentifier)
            utterance.prefersAssistiveTechnologySettings = true
        }
        Log.pipeline.info("speaking: \(utterance.prefersAssistiveTechnologySettings ? "iPhone Spoken Content voice" : (utterance.voice?.name ?? "-"), privacy: .public) (\(language, privacy: .public))")
        let levels = levels
        levels.reset()
        // The system synthesizer plays it itself, like Settings does. (Rendering it through our
        // own engine via write() for the orb's spectrum sounded worse than the same voice in
        // Settings.) The orb pulses on words instead.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let delegate = SpeechFinishDelegate {
                Task { @MainActor in
                    levels.wordSpoken()
                    self.turn.markOnce("first sound")
                }
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

    /// Glasses appear as a Bluetooth headset: HFP gives the glasses mic, A2DP the speakers.
    /// `glassesMic: false` (camera streaming): no HFP at all — HFP shares the Bluetooth radio
    /// with the camera link and drops it to 1-3 fps; the phone's mic listens, the answer still
    /// plays on the glasses over A2DP.
    static func activateAudioSession(glassesMic: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        // Recording with the glasses in the background: the session is already running (see
        // AudioKeepAlive); keep its category so the microphone may start while locked.
        if AudioKeepAlive.isOn {
            AudioKeepAlive.listeningOnGlasses = glassesMic
            try AudioKeepAlive.activate()
            if glassesMic, let bt = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(bt)
            } else if !glassesMic, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            return
        }
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
        if glassesMic { options.insert(hfpOption) }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // Smaller IO buffers → more frequent spectrum updates for the orb (a hint; iOS may ignore it).
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        // Prefer the glasses mic when allowed, the phone's own mic otherwise.
        if glassesMic, let bt = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(bt)
        } else if !glassesMic, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    /// Wake word heard: the listening earcon.
    func acknowledge() {
        guard phase == .idle || phase.isFailed else { return }
        playEarcon()
    }

    /// The glasses' side tap: start listening (after the earcon), or finish the question if
    /// already listening, or stop an answer being read.
    func pushToTalk() async {
        // One double tap reaches the app as two taps up to ~2 s apart: the late one must not
        // end the listening the first one started. Interrupting an answer needs no such wait
        // (an answer never starts within 2.5 s of the tap that asked for it).
        let sinceLast = Date().timeIntervalSince(lastPush)
        switch phase {
        case .listening:
            guard sinceLast > 2.5 else { return }
            lastPush = Date()
            await finishListening()
        case .speaking, .thinking:
            // The user has something else to say: stop and listen right away (before: a tap
            // while thinking did nothing, one while speaking only stopped the voice).
            guard sinceLast > 0.7 else { return }
            lastPush = Date()
            interrupted = true
            cancel()
            let waitStart = Date()
            while phase == .speaking || phase == .thinking, Date().timeIntervalSince(waitStart) < 1.5 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard phase == .idle || phase.isFailed else { return }
            await listenWithEarcon()
        default:
            guard sinceLast > 2.5 else { return }
            lastPush = Date()
            await listenWithEarcon()
        }
    }

    /// Soft rising two-note bell, then the microphone opens (the bell is over by then, so
    /// the recogniser does not hear it).
    func listenWithEarcon() async {
        turn = TurnTimeline()
        if glassesMic?.isFlowing == true {
            // The glasses mic is in the camera stream: nothing to switch, and words said during
            // the tone are heard (before: the first half second after the tap was not recorded).
            playEarcon()
            try? await Task.sleep(for: .milliseconds(120))
        } else if prefersGlassesMic(), await Self.prepareGlassesMic() {
            // The tone goes through the glasses on the mic profile: when it plays, they listen.
            playEarcon(keepRoute: true)
            try? await Task.sleep(for: .milliseconds(560))
        } else {
            playEarcon()
            try? await Task.sleep(for: .milliseconds(560))
        }
        await startListening()
    }

    @ObservationIgnored private var lastPush = Date.distantPast

    /// The iPhone's own "listening" tone (dictation / Voice Control), played through the
    /// glasses like the answers. Not a public interface: if it is missing, our own tone.
    private static let systemListenTone: URL? = {
        let names = ["jbl_begin.caf", "begin_record.caf"]
        let folders = ["/System/Library/Audio/UISounds/", "/System/Library/Audio/UISounds/Modern/"]
        for name in names {
            for folder in folders where FileManager.default.fileExists(atPath: folder + name) {
                return URL(fileURLWithPath: folder + name)
            }
        }
        return nil
    }()

    /// Bundled tones made by the team (ilk.wav / son.wav, silence trimmed to ~0.5 s): one when
    /// listening starts, one when it closes without a question.
    private static let listenStartTone = Bundle.main.url(forResource: "listen_start", withExtension: "m4a")
    private static let listenEndTone = Bundle.main.url(forResource: "listen_end", withExtension: "m4a")

    /// Listening closed without a question.
    func playEndTone() {
        guard let url = Self.listenEndTone, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        try? Self.activatePlaybackSession()
        earconPlayer = player
        player.volume = 0.8
        player.play()
    }

    private func playEarcon(keepRoute: Bool = false) {
        if !keepRoute { try? Self.activatePlaybackSession() }
        if let url = Self.listenStartTone ?? Self.systemListenTone, let player = try? AVAudioPlayer(contentsOf: url) {
            earconPlayer = player
            player.volume = 1
            player.play()
            return
        }
        earconPlayer = try? AVAudioPlayer(data: Self.earconWAV)
        earconPlayer?.volume = 0.9
        earconPlayer?.play()
    }

    @ObservationIgnored private var earconPlayer: AVAudioPlayer?
    @ObservationIgnored private var waitingPlayer: AVAudioPlayer?

    private func playWaitingTone() {
        if waitingPlayer == nil { waitingPlayer = try? AVAudioPlayer(data: Self.waitingWAV) }
        waitingPlayer?.volume = 0.35
        waitingPlayer?.currentTime = 0
        waitingPlayer?.play()
    }

    /// One soft low note (G4 with a quick fade), 0.18 s: "still working on it".
    static let waitingWAV: Data = {
        let rate = 44_100.0
        let total = Int(rate * 0.18)
        let samples = (0..<total).map { i -> Int16 in
            let t = Double(i) / rate
            let envelope = min(1, t / 0.008) * exp(-t / 0.05)
            return Int16(sin(2 * .pi * 392 * t) * envelope * 0.5 * Double(Int16.max))
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(44_100)); put(UInt32(88_200))
        put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.forEach { put($0) }
        return data
    }()

    /// Original earcon in the style of smart-glasses "listening" tones: two warm notes a fifth
    /// apart (C5 → G5), each with octave and twelfth partials that fade faster than the
    /// fundamental (a soft mallet sound) and a quiet sub-octave for body; 5 ms attack,
    /// exponential decay, the second note starting while the first rings. 44.1 kHz mono WAV.
    static let earconWAV: Data = {
        let rate = 44_100.0
        let total = Int(rate * 0.55)
        var mix = [Double](repeating: 0, count: total)
        for (freq, start, gain) in [(523.25, 0.0, 0.6), (783.99, 0.13, 0.55)] {
            let offset = Int(start * rate)
            for i in 0..<(total - offset) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.005)
                let body = exp(-t / 0.16)
                let bright = exp(-t / 0.06)
                let w = 2 * .pi * freq * t
                let tone = sin(w) * body
                    + 0.45 * sin(2 * w) * bright
                    + 0.20 * sin(3 * w) * bright
                    + 0.15 * sin(0.5 * w) * body
                mix[offset + i] += tone * attack * gain
            }
        }
        let peak = max(0.001, mix.map(abs).max() ?? 1)
        let samples = mix.map { Int16(($0 / peak) * 0.8 * Double(Int16.max)) }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(44_100)); put(UInt32(88_200))
        put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.forEach { put($0) }
        return data
    }()

    /// HFP (the glasses mic profile) plays everything as 8/16 kHz mono "phone line" audio; the
    /// switch to A2DP after listening takes a moment. Speak only once the output has left HFP
    /// (at most 1.5 s), and log the route and the installed voices once for diagnosis.
    static func waitForHighQualityOutput() async {
        let session = AVAudioSession.sharedInstance()
        func onHFP() -> Bool { session.currentRoute.outputs.contains { $0.portType == .bluetoothHFP } }
        if onHFP() {
            if AudioKeepAlive.isOn {
                try? AudioKeepAlive.activate()
            } else {
                try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try? session.setActive(true)
            }
            let start = Date()
            while onHFP(), Date().timeIntervalSince(start) < 1.5 { try? await Task.sleep(for: .milliseconds(100)) }
            Log.pipeline.info("output left HFP after \(Int(Date().timeIntervalSince(start) * 1000)) ms (still HFP: \(onHFP()))")
        }
        let out = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        Log.pipeline.info("speaking on \(out, privacy: .public) at \(Int(session.sampleRate)) Hz")
        if !loggedVoices {
            loggedVoices = true
            for language in ["en", "tr"] {
                let list = VoicePicker.voices(for: language).map { "\($0.name)/\(VoicePicker.qualityLabel($0))/\($0.language)" }
                Log.pipeline.info("installed \(language, privacy: .public) voices: \(list.joined(separator: ", "), privacy: .public)")
            }
        }
    }

    private static var loggedVoices = false

    nonisolated static var hfpOption: AVAudioSession.CategoryOptions {
        if #available(iOS 26.0, *) { return .allowBluetoothHFP }
        return AVAudioSession.CategoryOptions(rawValue: 0x4)   // .allowBluetooth
    }

    /// Switches to the glasses mic (HFP) and waits until it is the input (at most 2 s), so the
    /// "listening" tone plays only when the glasses can really hear. Returns whether it is.
    static func prepareGlassesMic() async -> Bool {
        try? activateAudioSession(glassesMic: true)
        let session = AVAudioSession.sharedInstance()
        func ready() -> Bool { session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP } }
        let start = Date()
        while !ready(), Date().timeIntervalSince(start) < 2 {
            if let bt = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) { try? session.setPreferredInput(bt) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let ok = ready()
        Log.pipeline.info("glasses mic \(ok ? "ready" : "not available", privacy: .public) after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return ok
    }

    static func activatePlaybackSession() throws {
        if AudioKeepAlive.isOn {
            AudioKeepAlive.listeningOnGlasses = false
            return try AudioKeepAlive.activate()
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    /// Hands the route back (camera transfers share the Bluetooth link with HFP).
    static func deactivateAudioSession() {
        if AudioKeepAlive.isOn {
            // Stays on while the glasses record; only leave the mic profile (back to A2DP).
            if AudioKeepAlive.listeningOnGlasses {
                AudioKeepAlive.listeningOnGlasses = false
                try? AudioKeepAlive.activate()
            }
            return
        }
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

/// When each step of a spoken turn happened, as seconds from the tap ("mic open 0.3 · last
/// word 2.1 · end of question 3.3 · answer ready 4.2 · first sound 4.4").
struct TurnTimeline {
    private let start = ContinuousClock.now
    private var marks: [(name: String, at: Double)] = []

    mutating func mark(_ name: String) {
        let at = (ContinuousClock.now - start).seconds
        if let i = marks.firstIndex(where: { $0.name == name }) { marks[i].at = at } else { marks.append((name, at)) }
    }

    mutating func markOnce(_ name: String) {
        if !marks.contains(where: { $0.name == name }) { mark(name) }
    }

    var summary: String {
        var parts = marks.map { "\($0.name) \(String(format: "%.1f", $0.at))" }
        if let heard = marks.first(where: { $0.name == "last word" })?.at,
           let sound = marks.first(where: { $0.name == "first sound" })?.at {
            parts.append("silence→sound \(String(format: "%.1f", sound - heard)) s")
        }
        return parts.joined(separator: " · ")
    }
}

private protocol ListeningSession: AnyObject {
    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws
    func stop()
}

/// Recognition on the glasses mic audio from the camera stream (no iPhone microphone).
private final class TapSpeechSession: ListeningSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let tap: GlassesMicTap
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, contextualStrings: [String], tap: GlassesMicTap) {
        self.recognizer = recognizer
        self.tap = tap
        request.contextualStrings = contextualStrings
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws {
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.taskHint = .search
        let request = request
        let analyzer = SpectrumAnalyzer()
        tap.setConsumer { buffer in
            request.append(buffer)
            if let frame = analyzer.process(buffer) { onFrame(frame) }
        }
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result {
                onText(result.bestTranscription.formattedString, result.isFinal)
            } else if let error {
                onError(error.localizedDescription)
            }
        }
    }

    func stop() {
        tap.setConsumer(nil)
        request.endAudio()
        task?.finish()
        task = nil
    }
}

/// AVAudioEngine + recognition task. Callbacks arrive on audio / recognizer threads.
private final class SpeechSession: ListeningSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, contextualStrings: [String] = []) {
        self.recognizer = recognizer
        request.contextualStrings = contextualStrings
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) throws {
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
                          userInfo: [NSLocalizedDescriptionKey: "The microphone isn't ready. Try again."])
        }
        let request = request
        let analyzer = SpectrumAnalyzer()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            request.append(buffer)
            if let frame = analyzer.process(buffer) { onFrame(frame) }
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
