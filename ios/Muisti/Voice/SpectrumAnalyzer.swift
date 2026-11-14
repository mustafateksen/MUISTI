@preconcurrency import AVFoundation
import Accelerate

/// RMS level plus log-spaced voice bands (0…1) from audio buffers, for the voice orb.
/// Hann window → 1024-point real FFT → 80 Hz…8 kHz in `bandCount` bands → dB → 0…1, with a
/// small treble tilt (speech energy falls off with frequency, so high bands would stay dark).
/// Runs on an audio thread; one instance per stream, used serially.
final class SpectrumAnalyzer: @unchecked Sendable {
    struct Frame: Sendable {
        let level: Float
        let bands: [Float]
    }

    static let bandCount = 32

    private let fftSize = 1024
    private let half = 512
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private var bandRanges: [Range<Int>] = []
    private var sampleRate: Double = 0

    private let minFreq: Float = 80
    private let dbFloor: Float = -70
    private let dbCeil: Float = -15
    private let tiltDB: Float = 12

    init() {
        fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        windowed = .allocate(capacity: fftSize)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        magnitudes = .allocate(capacity: half)
    }

    deinit {
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Frame? {
        guard let fft, let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.sampleRate > 0 else { return nil }
        if buffer.format.sampleRate != sampleRate { configureBands(sampleRate: buffer.format.sampleRate) }

        // Newest `fftSize` samples (taps often deliver ~100 ms buffers).
        let n = min(frames, fftSize)
        let src = channel + (frames - n)

        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: src, count: n))
        let level = Self.clamp01((20 * log10(max(rms, 1e-7)) + 50) / 45)   // -50…-5 dBFS

        window.withUnsafeBufferPointer { w in
            vDSP_vmul(src, 1, w.baseAddress!, 1, windowed, 1, vDSP_Length(n))
        }
        if n < fftSize { (windowed + n).update(repeating: 0, count: fftSize - n) }

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        var out = split
        fft.forward(input: split, output: &out)
        vDSP_zvabs(&out, 1, magnitudes, 1, vDSP_Length(half))
        var scale = 2 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(half))

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for (i, range) in bandRanges.enumerated() {
            var mean: Float = 0
            vDSP_meanv(magnitudes + range.lowerBound, 1, &mean, vDSP_Length(range.count))
            let tilt = tiltDB * Float(i) / Float(Self.bandCount - 1)
            let db = 20 * log10(max(mean, 1e-9)) + tilt
            bands[i] = Self.clamp01((db - dbFloor) / (dbCeil - dbFloor))
        }
        return Frame(level: level, bands: bands)
    }

    private func configureBands(sampleRate rate: Double) {
        sampleRate = rate
        let binHz = Float(rate) / Float(fftSize)
        // Bluetooth HFP tops out at 4 or 8 kHz.
        let maxFreq = min(8_000, Float(rate) / 2 * 0.95)
        let ratio = maxFreq / minFreq
        bandRanges = (0..<Self.bandCount).map { i in
            let lo = max(1, Int(minFreq * pow(ratio, Float(i) / Float(Self.bandCount)) / binHz))
            let hiFreq = minFreq * pow(ratio, Float(i + 1) / Float(Self.bandCount))
            let hi = min(half, max(lo + 1, Int((hiFreq / binHz).rounded(.up))))
            return min(lo, half - 1)..<hi
        }
    }

    private static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
}
