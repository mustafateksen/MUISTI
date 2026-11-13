import AVFoundation

/// Section 11 boundary with Kişi 4: this line only sets the audio session up correctly.
/// The glasses appear as a Bluetooth audio device; mic and speaker go through the system
/// route. Not called automatically — Kişi 4 calls it before speech recognition.
///
/// Risk to test with real glasses: opening the Bluetooth mic drops the route to the
/// hands-free profile and may squeeze the camera's Bluetooth bandwidth.
enum AudioSessionSetup {
    static func configureForVoice() throws {
        let session = AVAudioSession.sharedInstance()
        let bluetooth: AVAudioSession.CategoryOptions
        if #available(iOS 26.0, *) {
            bluetooth = .allowBluetoothHFP
        } else {
            bluetooth = AVAudioSession.CategoryOptions(rawValue: 0x4)   // .allowBluetooth
        }
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [bluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
