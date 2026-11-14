@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Siri-like listening: the glasses microphone's audio, streamed with the video as 16 kHz PCM
/// (DAT camera audio; no Bluetooth HFP, so the camera keeps its bandwidth), runs continuously
/// through the phone's on-device recogniser. The recogniser is biased to the wake word and the
/// names in memory (`contextualStrings`), so "Muisti" is heard as Muisti and not as "music",
/// as the glasses' own English recogniser does.
///
/// An utterance ends after a short pause; it is then handed to `GlassesSpeech` (wake word,
/// question) and recognition starts afresh. Requests are also renewed every ~50 s (the
/// recogniser limits one request to about a minute).
final class GlassesAudioRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var lastText = ""
    private var lastChange = Date()
    private var startedAt = Date()
    private var running = false
    private var strings: [String] = []
    private var onUtterance: @Sendable (String) -> Void = { _ in }
    private var onPartial: @Sendable (String) -> Void = { _ in }
    private let queue = DispatchQueue(label: "fi.junction.muisti.wake")

    /// Pause that ends an utterance.
    private let pause: TimeInterval = 0.8

    func start(contextualStrings: [String], onPartial: @escaping @Sendable (String) -> Void = { _ in },
               onUtterance: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !running, recognizer?.isAvailable == true else { return }
        running = true
        strings = contextualStrings
        self.onUtterance = onUtterance
        self.onPartial = onPartial
        beginLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        Log.glasses.info("glasses audio wake listener started")
    }

    func updateStrings(_ contextualStrings: [String]) {
        lock.lock()
        strings = contextualStrings
        lock.unlock()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lastText = ""
    }

    /// Called on the SDK's audio thread for every frame.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = running ? self.request : nil
        lock.unlock()
        request?.append(buffer)
    }

    private func beginLocked() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.taskHint = .dictation
        request.contextualStrings = strings
        self.request = request
        lastText = ""
        lastChange = Date()
        startedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.lock.lock()
            var partial: (@Sendable (String) -> Void)?
            if self.request === request, text != self.lastText {
                self.lastText = text
                self.lastChange = Date()
                partial = self.onPartial
            }
            self.lock.unlock()
            partial?(text)
        }
    }

    private func tick() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let now = Date()
        var utterance: String?
        if !lastText.isEmpty, now.timeIntervalSince(lastChange) >= pause {
            utterance = lastText
        }
        if utterance != nil || now.timeIntervalSince(startedAt) > 50 {
            request?.endAudio()
            task?.cancel()
            beginLocked()
        }
        let deliver = onUtterance
        lock.unlock()
        if let utterance { deliver(utterance) }
    }
}
