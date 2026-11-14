@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Observation
import os

/// Fallback source: the phone's back camera, for when there are no glasses and no mock.
/// Stream modes emit frames at the configured rate; adaptive/interval modes only encode the
/// latest frame when the scheduler asks, so the phone does not JPEG-encode 30 frames a second.
@Observable
@MainActor
final class PhoneCameraSource: CaptureSource {
    let kind: SourceKind = .phone

    private(set) var state: CaptureState = .idle {
        didSet { if state != oldValue { stateContinuation.yield(state) } }
    }

    @ObservationIgnored let frames: AsyncStream<CapturedFrame>
    @ObservationIgnored let states: AsyncStream<CaptureState>
    @ObservationIgnored private let frameContinuation: AsyncStream<CapturedFrame>.Continuation
    @ObservationIgnored private let stateContinuation: AsyncStream<CaptureState>.Continuation
    @ObservationIgnored private let engine = PhoneCameraEngine()

    init() {
        (frames, frameContinuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(2))
        (states, stateContinuation) = AsyncStream.makeStream(of: CaptureState.self, bufferingPolicy: .bufferingNewest(8))
    }

    func start(config: CaptureConfig) async {
        state = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .failed(message: "iPhone camera access wasn't granted.")
                return
            }
        default:
            state = .failed(message: "No iPhone camera access. Turn it on in Settings > Muisti.")
            return
        }
        let emitEvery: Double? = config.mode.usesScheduler ? nil : 1.0 / Double(config.streamFPS)
        let ok = await engine.start(emitInterval: emitEvery, continuation: frameContinuation)
        state = ok ? .running : .failed(message: "This device has no rear camera (use mock glasses in the simulator).")
    }

    func stop() async {
        await engine.stop()
        state = .idle
    }

    func captureStill(trigger: CaptureTrigger) async -> CapturedFrame? {
        guard state == .running, let jpeg = await engine.latestJPEG() else { return nil }
        return CapturedFrame(origin: .phoneCamera, jpeg: jpeg, pixelSize: ImageData.pixelSize(of: jpeg), isHighRes: false, trigger: trigger)
    }

    func requestHighResPhoto() async -> CapturedFrame? {
        guard state == .running, let data = await engine.capturePhoto(), let jpeg = ImageData.ensureJPEG(data) else {
            return nil
        }
        return CapturedFrame(origin: .phoneCamera, jpeg: jpeg, pixelSize: ImageData.pixelSize(of: jpeg), isHighRes: true, trigger: .highRes)
    }
}

/// AVFoundation work on its own serial queue. All mutable state is guarded by `lock` or
/// only touched on `queue`.
final class PhoneCameraEngine: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    private struct Shared {
        var emitInterval: Double?
        var lastEmit: Double = 0
        var latest: CMSampleBuffer?
        var continuation: AsyncStream<CapturedFrame>.Continuation?
        var photoWaiter: CheckedContinuation<Data?, Never>?
    }

    private let queue = DispatchQueue(label: "fi.junction.muisti.phonecam", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let lock = NSLock()
    private var shared = Shared()   // guarded by `lock`
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configured = false

    func start(emitInterval: Double?, continuation: AsyncStream<CapturedFrame>.Continuation) async -> Bool {
        lock.withLock {
            shared.emitInterval = emitInterval
            shared.continuation = continuation
            shared.lastEmit = 0
        }
        return await withCheckedContinuation { done in
            queue.async {
                guard self.configureIfNeeded() else { return done.resume(returning: false) }
                if !self.session.isRunning { self.session.startRunning() }
                done.resume(returning: true)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.lock.withLock { self.shared.latest = nil }
                done.resume()
            }
        }
    }

    func latestJPEG() async -> Data? {
        guard let buffer = lock.withLock({ shared.latest }) else { return nil }
        let box = UncheckedBox(buffer)
        return await withCheckedContinuation { done in
            queue.async { done.resume(returning: self.encode(box.value)) }
        }
    }

    func capturePhoto() async -> Data? {
        await withCheckedContinuation { waiter in
            let busy = lock.withLock { () -> Bool in
                if shared.photoWaiter != nil { return true }
                shared.photoWaiter = waiter
                return false
            }
            if busy { return waiter.resume(returning: nil) }
            queue.async {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Setup (on `queue`)

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90   // portrait, like the glasses
            }
        }
        // The 720p preset would also cap stills at 720p; open the photo output to the largest
        // size this camera format supports so "High-res" means something.
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        session.commitConfiguration()

        // 15 fps is plenty for a backup source and saves power.
        if (try? device.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: 15)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        }
        configured = true
        return true
    }

    private func encode(_ buffer: CMSampleBuffer) -> Data? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
        return ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: pixels), colorSpace: space, options: options)
    }

    // MARK: Delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let emit: AsyncStream<CapturedFrame>.Continuation? = lock.withLock {
            shared.latest = sampleBuffer
            guard let interval = shared.emitInterval, now - shared.lastEmit >= interval else { return nil }
            shared.lastEmit = now
            return shared.continuation
        }
        guard let emit, let jpeg = encode(sampleBuffer) else { return }
        emit.yield(CapturedFrame(origin: .phoneCamera, jpeg: jpeg, pixelSize: ImageData.pixelSize(of: jpeg), isHighRes: false, trigger: .stream))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { shared.photoWaiter = nil }
            return shared.photoWaiter
        }
        waiter?.resume(returning: data)
    }
}

/// Moves a CoreMedia buffer to our own serial queue; it is never touched concurrently.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
