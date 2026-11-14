@preconcurrency import AVFoundation

/// Speaks an answer through `AVAudioEngine` (synthesizer → buffers → player node) so the orb can
/// react to the answer's own voice. Returns `false` when this path is unavailable; the caller
/// then falls back to `AVSpeechSynthesizer.speak`.
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    // Guarded by `lock`.
    private var finish: ((Bool) -> Void)?
    private var pending = 0
    private var writingDone = false
    private var played = false
    private var connectedFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var onFrame: (@Sendable (SpectrumAnalyzer.Frame) -> Void)?

    override init() {
        super.init()
        engine.attach(player)
        synthesizer.delegate = self
    }

    /// Speaks and waits until the audio has played out (or `stop()`).
    func speak(_ utterance: AVSpeechUtterance, onFrame: @escaping @Sendable (SpectrumAnalyzer.Frame) -> Void) async -> Bool {
        let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            lock.withLock {
                pending = 0
                writingDone = false
                played = false
                self.onFrame = onFrame
                finish = { done.resume(returning: $0) }
            }
            synthesizer.write(utterance) { [weak self] buffer in
                self?.receive(buffer)
            }
        }
        player.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        return ok
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        complete(true)
    }

    // MARK: Buffers

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
            lock.withLock { writingDone = true }
            completeIfDrained()
            return
        }
        guard let floats = floatBuffer(from: pcm) else { complete(false); return }
        if !engine.isRunning {
            guard start(format: floats.format) else { complete(false); return }
        }
        lock.withLock {
            pending += 1
            played = true
        }
        player.scheduleBuffer(floats, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            lock.withLock { pending -= 1 }
            completeIfDrained()
        }
    }

    private func start(format: AVAudioFormat) -> Bool {
        if connectedFormat != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        let analyzer = SpectrumAnalyzer()
        let onFrame = lock.withLock { self.onFrame }
        player.removeTap(onBus: 0)
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            if let frame = analyzer.process(buffer) { onFrame?(frame) }
        }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            return true
        } catch {
            player.removeTap(onBus: 0)
            return false
        }
    }

    /// Standard (Float32, deinterleaved) copy: the mixer only takes float input.
    private func floatBuffer(from pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: pcm.format.sampleRate,
                                         channels: pcm.format.channelCount) else { return nil }
        if pcm.format == target { return pcm }
        if converter?.inputFormat != pcm.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: pcm.format, to: target)
        }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: pcm.frameLength) else { return nil }
        do {
            try converter.convert(to: out, from: pcm)
            return out
        } catch {
            return nil
        }
    }

    // MARK: Completion

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.withLock { writingDone = true }
        completeIfDrained()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(true)
    }

    private func completeIfDrained() {
        let (drained, ok) = lock.withLock { (writingDone && pending <= 0, played) }
        if drained { complete(ok) }
    }

    /// Resumes the waiting `speak` exactly once.
    private func complete(_ ok: Bool) {
        let callback = lock.withLock {
            let callback = finish
            finish = nil
            return callback
        }
        callback?(ok)
    }
}
