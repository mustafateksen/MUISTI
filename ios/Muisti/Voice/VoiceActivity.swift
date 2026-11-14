import AVFoundation
import Accelerate
import os

/// "Is the user still talking?" from the audio itself. The newer speech models report words
/// in bursts, seconds apart; ending a question after 1.8 s without new words cut people off
/// mid-sentence (16 of 30 real recordings in the Mac harness). This tracks the background
/// level and calls a buffer voice when it is clearly above it.
final class VoiceActivity: @unchecked Sendable {
    private struct State {
        var floor: Float = -60        // background level, dBFS
        var voicedFrames = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// How far above the background a buffer must be to count as voice.
    var margin: Float = 10
    /// Never voice below this (digital silence, a muted stream).
    var absoluteFloor: Float = -52

    /// True when this buffer holds voice.
    func isVoice(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData?[0] ?? nil, buffer.frameLength > 0 else {
            return isVoiceInt16(buffer)
        }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        return judge(20 * log10(max(rms, 1e-7)))
    }

    private func isVoiceInt16(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return false }
        var sum: Double = 0
        for i in 0..<Int(buffer.frameLength) { let v = Double(data[i]) / 32768; sum += v * v }
        return judge(Float(10 * log10(max(sum / Double(buffer.frameLength), 1e-14))))
    }

    private func judge(_ db: Float) -> Bool {
        state.withLock { s in
            let voice = db > max(s.floor + margin, absoluteFloor)
            // The floor follows quiet stretches quickly and loud ones slowly, so speech does not
            // drag it up but a steady new background (a fan, a street) is learned in seconds.
            if db < s.floor { s.floor = db } else if !voice { s.floor += min(db - s.floor, 0.6) } else { s.floor += 0.02 }
            return voice
        }
    }
}
