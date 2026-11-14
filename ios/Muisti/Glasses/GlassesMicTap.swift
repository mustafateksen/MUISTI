@preconcurrency import AVFoundation
import Foundation
import os

/// The glasses microphone as it arrives inside the camera stream (DAT camera audio, 16 kHz
/// mono PCM). Push-to-talk listens here instead of opening the iPhone's microphone:
/// - it is the glasses mic, without switching the Bluetooth link to the hands-free profile
///   (answers keep playing in A2DP quality, no 1–2 s profile switch);
/// - it works with the phone locked: iOS does not let a background app start its own
///   microphone (`kAUStartIO` 'what', field log 14 Nov), but this audio is just data from the
///   glasses.
final class GlassesMicTap: @unchecked Sendable {
    private struct State {
        var consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var lastBuffer: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on the SDK's audio thread for every audio frame.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let consumer = state.withLock { s -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            s.lastBuffer = Date()
            return s.consumer
        }
        consumer?(buffer)
    }

    /// Audio arrived within the last second (the stream carries the mic now).
    var isFlowing: Bool {
        state.withLock { $0.lastBuffer.map { Date().timeIntervalSince($0) < 1 } ?? false }
    }

    func setConsumer(_ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        state.withLock { $0.consumer = consumer }
    }
}
