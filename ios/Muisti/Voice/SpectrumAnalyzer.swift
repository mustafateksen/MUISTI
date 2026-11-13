@preconcurrency import AVFoundation
import Accelerate

/// Turns microphone buffers into a few log-spaced voice bands (0…1) for the Ask visualizer.
/// Runs on the audio tap thread; one instance per listening session, used serially.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 32
    private static let fftSize = 1024

    private let dft: vDSP.DFT<Float>?
    private let window: [Float]
    private let zeros: [Float]

    init() {
        dft = vDSP.DFT(count: Self.fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        zeros = [Float](repeating: 0, count: Self.fftSize)
    }

    /// Band levels for the newest `fftSize` samples of the buffer's first channel.
    func bands(for buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let dft, let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let n = Self.fftSize
        var samples = [Float](repeating: 0, count: n)
        let take = min(frames, n)
        samples.withUnsafeMutableBufferPointer { out in
            for i in 0..<take { out[n - take + i] = channel[frames - take + i] }
        }
        samples = vDSP.multiply(samples, window)
        let (real, imaginary) = dft.transform(inputReal: samples, inputImaginary: zeros)

        let half = n / 2
        var magnitudes = [Float](repeating: 0, count: half)
        for i in 0..<half {
            magnitudes[i] = (real[i] * real[i] + imaginary[i] * imaginary[i]).squareRoot() / Float(n)
        }

        // Voice lives between ~80 Hz and ~8 kHz (Bluetooth HFP tops out at 4 or 8 kHz).
        let sampleRate = Float(buffer.format.sampleRate)
        let binWidth = sampleRate / Float(n)
        let low: Float = 80
        let high = min(8_000, sampleRate / 2 * 0.95)
        guard high > low, binWidth > 0 else { return nil }

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = low * pow(high / low, Float(b) / Float(Self.bandCount))
            let f1 = low * pow(high / low, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / binWidth))
            let i1 = min(half - 1, max(i0, Int(f1 / binWidth)))
            var peak: Float = 0
            for i in i0...i1 { peak = max(peak, magnitudes[i]) }
            // -75 dB … -15 dB → 0 … 1, a little lift for higher bands (voice energy falls off).
            let db = 20 * log10(peak + 1e-9) + Float(b) * 0.35
            bands[b] = min(max((db + 75) / 60, 0), 1)
        }
        return bands
    }
}
