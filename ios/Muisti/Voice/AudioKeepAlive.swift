import AVFoundation

/// iOS lets a backgrounded app start the microphone only while its audio session is already
/// running: a double tap on the glasses with the phone locked otherwise fails with
/// `AVAudioEngine` error 'what' (2003329396). While the glasses are recording, Muisti keeps a
/// play-and-record session active and plays silence (output only — the microphone stays off
/// until the user asks). It mixes with other audio, so music keeps playing.
@MainActor
enum AudioKeepAlive {
    private(set) static var isOn = false
    private static var engine: AVAudioEngine?
    private static var observers: [NSObjectProtocol] = []
    private static var engineObserver: NSObjectProtocol?

    /// The category every Muisti sound uses while the keep-alive runs (so nothing switches it
    /// to playback-only, which would block the microphone again). No HFP: the camera link keeps
    /// its bandwidth; answers play on the glasses over A2DP.
    static let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]

    /// Listening through the glasses mic: the session also allows HFP (a restart of the
    /// keep-alive must not take the mic away mid-question). Off again for answers (A2DP).
    static var listeningOnGlasses = false

    static var currentOptions: AVAudioSession.CategoryOptions {
        listeningOnGlasses ? options.union(VoiceAssistant.hfpOption) : options
    }

    static func start() {
        guard !isOn else { return }
        isOn = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                if ended { Task { @MainActor in restart(reason: "interruption ended") } }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in restart(reason: "media services reset") }
            },
        ]
        run()
    }

    static func stop() {
        guard isOn else { return }
        isOn = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        dropEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.glasses.info("audio keep-alive off")
    }

    /// Makes the session active in the keep-alive category (call before playing or listening).
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        let wanted = currentOptions
        if session.category != .playAndRecord || session.categoryOptions != wanted {
            try session.setCategory(.playAndRecord, mode: .default, options: wanted)
        }
        try session.setActive(true)
    }

    private static func restart(reason: String) {
        guard isOn else { return }
        Log.glasses.info("audio keep-alive restart: \(reason, privacy: .public)")
        dropEngine()
        run()
    }

    private static func dropEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.stop()
        engine = nil
    }

    private static func run() {
        do {
            try activate()
        } catch {
            Log.glasses.info("audio keep-alive: session failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
        buffer.frameLength = 22_050   // 1 s of silence, looped
        do {
            try engine.start()
        } catch {
            Log.glasses.info("audio keep-alive: engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        // A route change (glasses connect, a call) stops the engine: start it again.
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in restart(reason: "audio configuration changed") }
        }
        Log.glasses.info("audio keep-alive on (silent, mic off)")
    }
}
