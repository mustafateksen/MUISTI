// VoiceVisualizer.swift
// iOS 17+ / macOS 14+  —  SwiftUI + AVAudioEngine + Accelerate
// Info.plist: NSMicrophoneUsageDescription eklemeyi unutma.

import SwiftUI
import AVFoundation
import Accelerate

// MARK: - 1) DSP: RMS + FFT + log-spaced bantlar (ses thread'inde çalışır)

final class SpectrumAnalyzer: @unchecked Sendable {
    struct Frame: Sendable { let level: Float; let bands: [Float] }

    let fftSize: Int
    let bandCount: Int
    private let half: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private var bandRanges: [Range<Int>] = []
    private var sampleRate: Double = 0

    // Ayar parametreleri
    var minFreq: Float = 80        // ses için anlamlı aralık
    var maxFreq: Float = 8000
    var dbFloor: Float = -70       // bant dB -> 0...1 eşlemesi
    var dbCeil: Float = -15
    var tiltDB: Float = 12         // tiz bantları biraz yükselt (ses spektrumu doğal olarak düşer)

    init(fftSize: Int = 1024, bandCount: Int = 32) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize 2'nin kuvveti olmalı")
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.half = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                  count: fftSize, isHalfWindow: false)
        windowed   = .allocate(capacity: fftSize)
        realp      = .allocate(capacity: fftSize / 2)
        imagp      = .allocate(capacity: fftSize / 2)
        magnitudes = .allocate(capacity: fftSize / 2)
    }

    deinit {
        windowed.deallocate(); realp.deallocate(); imagp.deallocate(); magnitudes.deallocate()
    }

    private func configureBands(sampleRate sr: Double) {
        sampleRate = sr
        let binHz = Float(sr) / Float(fftSize)
        let ratio = maxFreq / minFreq
        bandRanges = (0..<bandCount).map { i in
            let fLo = minFreq * pow(ratio, Float(i) / Float(bandCount))
            let fHi = minFreq * pow(ratio, Float(i + 1) / Float(bandCount))
            let lo = max(1, Int(fLo / binHz))                 // bin 0 = DC (packed), atla
            let hi = min(half, max(lo + 1, Int(ceil(fHi / binHz))))
            return lo..<hi
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Frame? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if buffer.format.sampleRate != sampleRate { configureBands(sampleRate: buffer.format.sampleRate) }

        // En yeni fftSize örneği al (tap büyük buffer verebilir)
        let n = min(frames, fftSize)
        let src = channel + (frames - n)

        // --- RMS -> 0...1
        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: src, count: n))
        let rmsDB = 20 * log10(max(rms, 1e-7))
        let level = clamp01((rmsDB + 50) / 45)               // -50 dBFS..-5 dBFS

        // --- Hann pencere + zero-pad
        window.withUnsafeBufferPointer { w in
            vDSP_vmul(src, 1, w.baseAddress!, 1, windowed, 1, vDSP_Length(n))
        }
        if n < fftSize { (windowed + n).update(repeating: 0, count: fftSize - n) }

        // --- Real FFT (packed split complex)
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        var out = split
        fft.forward(input: split, output: &out)
        vDSP_zvabs(&out, 1, magnitudes, 1, vDSP_Length(half))

        // Ölçek: tam-ölçek sinüs ≈ 1.0 olacak şekilde (zrip x2, Hann x0.5)
        var scale = 2 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(half))

        // --- Bantlara topla, dB'ye çevir, normalize et
        var bands = [Float](repeating: 0, count: bandCount)
        for (i, r) in bandRanges.enumerated() {
            var mean: Float = 0
            vDSP_meanv(magnitudes + r.lowerBound, 1, &mean, vDSP_Length(r.count))
            let tilt = tiltDB * Float(i) / Float(max(bandCount - 1, 1))
            let db = 20 * log10(max(mean, 1e-9)) + tilt
            bands[i] = clamp01((db - dbFloor) / (dbCeil - dbFloor))
        }
        return Frame(level: level, bands: bands)
    }

    @inline(__always) private func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
}

// MARK: - 2) Ses motoru + UI'ya yayın (MainActor, @Observable)

enum AgentVoiceState: Sendable { case idle, listening, thinking, speaking }

@MainActor
@Observable
final class VoiceLevelMonitor {
    private(set) var level: Float = 0
    private(set) var bands: [Float]
    var state: AgentVoiceState = .idle

    // Yükselişte hızlı, düşüşte yavaş — "canlı" hissin %80'i bu
    var attack: Float = 0.55
    var release: Float = 0.12

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let analyzer: SpectrumAnalyzer

    init(bandCount: Int = 32) {
        analyzer = SpectrumAnalyzer(fftSize: 1024, bandCount: bandCount)
        bands = .init(repeating: 0, count: bandCount)
    }

    /// Mikrofonu dinle (kullanıcı konuşurken).
    func startMicrophone() async throws {
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "VoiceLevelMonitor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon izni yok"])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        // Agent kendi TTS'ini mikrofondan geri duymasın (AEC):
        try? input.setVoiceProcessingEnabled(true)

        installTap(on: input)
        engine.prepare()
        try engine.start()
        state = .listening
    }

    /// Agent konuşurken: TTS'i çalan node'a (AVAudioPlayerNode / mainMixerNode) tap at.
    /// Aynı engine'e bağlı olmalı.
    func visualizeOutput(of node: AVAudioNode) {
        installTap(on: node)
        state = .speaking
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .idle
        level = 0
        bands = .init(repeating: 0, count: bands.count)
    }

    var audioEngine: AVAudioEngine { engine }

    private func installTap(on node: AVAudioNode) {
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        let analyzer = self.analyzer
        // NOT: bufferSize sadece ipucu; iOS bazen ~100 ms'lik buffer verir.
        // Daha akıcı istersen AVAudioSinkNode kullan (IO buffer boyutunda, ~10 ms).
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let frame = analyzer.process(buffer) else { return }
            Task { @MainActor [weak self] in self?.apply(frame) }
        }
    }

    private func apply(_ f: SpectrumAnalyzer.Frame) {
        level = smooth(level, f.level)
        var next = bands
        for i in next.indices { next[i] = smooth(next[i], f.bands[i]) }
        bands = next   // tek atama = tek invalidation
    }

    private func smooth(_ old: Float, _ new: Float) -> Float {
        old + (new - old) * (new > old ? attack : release)
    }
}

// MARK: - 3a) Spektrum barları (ortadan simetrik, kapsül barlar)

struct SpectrumBarsView: View {
    var monitor: VoiceLevelMonitor
    var colors: [Color] = [.cyan, .blue, .purple, .pink]

    var body: some View {
        let bands = monitor.bands   // body'de oku -> Observation tracking
        Canvas { ctx, size in
            // Bas'ı ortaya, tizi kenarlara koy: [tiz ... bas bas ... tiz]
            let mirrored = Array(bands.reversed()) + bands
            let count = mirrored.count
            let gap: CGFloat = 3
            let barW = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let gradient = Gradient(colors: colors)

            for (i, v) in mirrored.enumerated() {
                let h = max(barW, CGFloat(v) * size.height)
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                ctx.fill(path, with: .linearGradient(gradient,
                                                     startPoint: CGPoint(x: 0, y: size.height),
                                                     endPoint: CGPoint(x: size.width, y: 0)))
            }
        }
        .drawingGroup() // Metal'de rasterize, 60/120 fps rahat
    }
}

// MARK: - 3b) Siri/ChatGPT tarzı organik "orb" (Canvas, shader'sız)

struct VoiceOrbView: View {
    var monitor: VoiceLevelMonitor

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let level = CGFloat(monitor.level)
                let bands = monitor.bands
                let low  = CGFloat(avg(bands.prefix(bands.count / 3)))
                let high = CGFloat(avg(bands.suffix(bands.count / 3)))
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.28

                // Durum bazlı davranış
                let speed: Double = switch monitor.state {
                    case .thinking: 2.6
                    case .speaking: 1.6
                    case .listening: 1.2
                    case .idle: 0.6
                }
                let breathe = monitor.state == .idle ? 0.04 * sin(t * 1.5) : 0

                ctx.addFilter(.blur(radius: 18 + level * 10))
                ctx.blendMode = .plusLighter

                let layers: [(Color, Double, CGFloat)] = [
                    (.cyan,   0.0, 1.00),
                    (.purple, 2.1, 0.92),
                    (.pink,   4.2, 0.85),
                ]
                for (color, phase, scale) in layers {
                    let r = base * scale * (1 + level * 0.45 + breathe)
                    let path = blob(center: c, radius: r, time: t * speed + phase,
                                    wobble: 0.06 + low * 0.25, detail: high * 0.12)
                    ctx.fill(path, with: .radialGradient(
                        Gradient(colors: [color.opacity(0.95), color.opacity(0.0)]),
                        center: c, startRadius: 0, endRadius: r * 1.3))
                }
            }
        }
    }

    /// Sinüs toplamıyla bozulmuş daire -> organik blob
    private func blob(center: CGPoint, radius: CGFloat, time: Double,
                      wobble: CGFloat, detail: CGFloat, points: Int = 96) -> Path {
        var path = Path()
        for i in 0...points {
            let a = Double(i) / Double(points) * 2 * .pi
            let d = wobble * CGFloat(sin(a * 3 + time) * 0.6 + sin(a * 2 - time * 1.3) * 0.4)
                  + detail * CGFloat(sin(a * 7 + time * 2.7))
            let r = radius * (1 + d)
            let p = CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    private func avg<S: Collection>(_ s: S) -> Float where S.Element == Float {
        s.isEmpty ? 0 : s.reduce(0, +) / Float(s.count)
    }
}

// MARK: - 3c) Metal shader'lı orb (VoiceOrb.metal gerekli, iOS 17+)

struct ShaderOrbView: View {
    var monitor: VoiceLevelMonitor
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = Float(timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 3600))
            GeometryReader { geo in
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.voiceOrb(
                        .float2(geo.size),
                        .float(t),
                        .float(monitor.level),
                        .float(bassEnergy)))
            }
        }
    }

    private var bassEnergy: Float {
        let b = monitor.bands.prefix(max(1, monitor.bands.count / 4))
        return b.reduce(0, +) / Float(b.count)
    }
}

// MARK: - Demo

struct VoiceAgentDemoView: View {
    @State private var monitor = VoiceLevelMonitor(bandCount: 24)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 40) {
                VoiceOrbView(monitor: monitor)        // veya ShaderOrbView
                    .frame(width: 280, height: 280)
                SpectrumBarsView(monitor: monitor)
                    .frame(height: 60)
                    .padding(.horizontal, 32)
            }
        }
        .task {
            do { try await monitor.startMicrophone() }
            catch { print("Audio error:", error) }
        }
        .onDisappear { monitor.stop() }
    }
}

#Preview { VoiceAgentDemoView() }
