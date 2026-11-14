import AVFoundation
import MediaPlayer

/// Taps on the glasses' side also reach the phone as media keys (like AirPods). Muisti claims
/// them as the "now playing" app while recording; a double tap (two play/pause keys within
/// 0.6 s, or "next track") is push-to-talk. If another app plays music, it gets the keys again.
@MainActor
final class MediaKeyTrigger {
    var onTap: () -> Void = {}
    private var targets: [Any] = []
    private var lastTap = Date.distantPast

    func activate() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            targets.append(command.addTarget { [weak self] _ in
                Task { @MainActor in self?.singleKey() }
                return .success
            })
        }
        center.nextTrackCommand.isEnabled = true
        targets.append(center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.fire() }
            return .success
        })
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Muisti",
            MPMediaItemPropertyArtist: String(localized: "Double tap to ask", comment: "Now Playing subtitle on the Lock Screen"),
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
        ]
        claimNowPlaying()
        Log.glasses.info("media key trigger on (touchpad tap = ask)")
    }

    func deactivate() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.nextTrackCommand] {
            targets.forEach { command.removeTarget($0) }
        }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// iOS routes media keys to the app that played audio last: a moment of silence makes
    /// Muisti that app.
    private func claimNowPlaying() {
        guard !AudioKeepAlive.isOn else { return }   // already playing (silence)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? session.setActive(true)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205) else { return }
        buffer.frameLength = 2_205   // 0.1 s of silence
        try? engine.start()
        player.scheduleBuffer(buffer) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { engine.stop() }
        }
        player.play()
    }

    private var lastKey: Date?

    /// One play/pause key = one tap; two within 0.6 s = double tap.
    private func singleKey() {
        let now = Date()
        if let last = lastKey, now.timeIntervalSince(last) < 0.6 {
            lastKey = nil
            fire()
        } else {
            lastKey = now
        }
    }

    private func fire() {
        // The SDK's touchpad event and the media key can both arrive for one tap.
        guard Date().timeIntervalSince(lastTap) > 1 else { return }
        lastTap = Date()
        Log.glasses.info("double tap on the side (media key): ask")
        onTap()
    }

    /// The SDK reported the same tap: count it so the media key does not fire again.
    func noteTap() { lastTap = Date() }

    var recentlyTapped: Bool { Date().timeIntervalSince(lastTap) <= 1 }
}
