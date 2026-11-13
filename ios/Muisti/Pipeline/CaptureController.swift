import Foundation
import MWDATCore
import Observation
import UIKit

/// Recorder + perception sink + upload queue, off the main actor, strictly in order.
actor FramePipeline {
    private var sink: any FrameSink
    private var customSink = false
    private var recordToDisk = true
    private var upload = true
    let recorder: SessionRecorder
    let queue: UploadQueue

    init(recorder: SessionRecorder, queue: UploadQueue) {
        self.recorder = recorder
        self.queue = queue
        sink = PassthroughSink(everyN: 5)
    }

    func configure(recordToDisk: Bool, upload: Bool, passthroughEveryN: Int) {
        self.recordToDisk = recordToDisk
        self.upload = upload
        if !customSink { sink = PassthroughSink(everyN: passthroughEveryN) }
    }

    /// Kişi 2 plugs the perception line in here.
    func setSink(_ sink: any FrameSink) {
        self.sink = sink
        customSink = true
    }

    /// Returns whether the frame was kept by the sink.
    func handle(_ frame: CapturedFrame) async -> Bool {
        if recordToDisk { await recorder.write(frame) }
        guard let payload = await sink.process(frame) else { return false }
        if upload { await queue.enqueue(payload, seenAt: frame.capturedAt) }
        return true
    }
}

struct FrameSummary: Equatable {
    let at: Date
    let origin: CaptureOrigin
    let trigger: CaptureTrigger
    let width: Int
    let height: Int
    let bytes: Int
    let isHighRes: Bool
    let hasLocation: Bool
}

/// The one object the UI talks to. Owns the sources, sensors, the adaptive scheduler and
/// the pipeline. Single consumer of every source's `frames`.
@Observable
@MainActor
final class CaptureController {
    let config: AppConfig
    let wearables: WearablesController
    let glasses: GlassesCaptureSource
    let phone: PhoneCameraSource
    let location = LocationProvider()
    let motion = MotionProvider()
    #if DEBUG
    let mock = MockDeviceController()
    #endif

    private(set) var isRunning = false
    private(set) var previewImage: UIImage?
    private(set) var lastFrame: FrameSummary?
    private(set) var capturedCount = 0
    private(set) var keptCount = 0
    private(set) var queueStatus = UploadQueueStatus()
    private(set) var schedulerText = "—"
    private(set) var movement: Movement = .unknown
    private(set) var batteryFactor: Double = 1
    private(set) var capturesLastMinute = 0
    private(set) var recordingFolder: String?
    var notice: String?

    var activeSource: any CaptureSource { config.sourceKind == .glasses ? glasses : phone }
    var state: CaptureState { activeSource.state }

    @ObservationIgnored private var scheduler: AdaptiveScheduler
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var lastFixedCapture: Date?
    @ObservationIgnored private var isCapturing = false
    /// Consecutive failed stills; each one doubles the pause before the next try (max 16 s).
    @ObservationIgnored private var failedStills = 0
    @ObservationIgnored private var retryNotBefore: Date?
    @ObservationIgnored private let recorder = SessionRecorder()
    @ObservationIgnored let uploadQueue = UploadQueue()
    @ObservationIgnored private let pipeline: FramePipeline
    @ObservationIgnored private let pipelineInput: AsyncStream<CapturedFrame>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(config: AppConfig, wearables: WearablesController) {
        self.config = config
        self.wearables = wearables
        glasses = GlassesCaptureSource()
        phone = PhoneCameraSource()
        scheduler = AdaptiveScheduler(tuning: config.tuning)
        pipeline = FramePipeline(recorder: recorder, queue: uploadQueue)

        let (pipelineStream, pipelineInput) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(8))
        self.pipelineInput = pipelineInput

        let pipeline = pipeline
        tasks.append(Task.detached { [weak self] in
            for await frame in pipelineStream {
                let kept = await pipeline.handle(frame)
                if kept { await self?.noteKept() }
            }
        })
        let glassesFrames = glasses.frames
        tasks.append(Task { [weak self] in
            for await frame in glassesFrames { self?.ingest(frame) }
        })
        let phoneFrames = phone.frames
        tasks.append(Task { [weak self] in
            for await frame in phoneFrames { self?.ingest(frame) }
        })
        let queueStatus = uploadQueue.statusStream
        tasks.append(Task { [weak self] in
            for await status in queueStatus { self?.queueStatus = status }
        })

        location.onFix = { [recorder] fix in
            Task { await recorder.record(fix) }
        }
        Task { [uploadQueue] in
            await uploadQueue.start(baseURL: config.serverURL, enabled: config.uploadEnabled)
        }
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
        schedulerTask?.cancel()
    }

    // MARK: Start / stop

    func start() async {
        notice = nil
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true   // backgrounding ends the glasses session
        UIDevice.current.isBatteryMonitoringEnabled = true
        await applySettings()

        if recordingFolder == nil, config.recordToDisk {
            recordingFolder = (try? await recorder.begin())?.lastPathComponent
        }
        location.start()
        if config.mode.usesScheduler { motion.start() }

        let other: any CaptureSource = config.sourceKind == .glasses ? phone : glasses
        if other.state != .idle { await other.stop() }

        scheduler = AdaptiveScheduler(tuning: config.tuning)
        lastFixedCapture = nil
        failedStills = 0
        retryNotBefore = nil
        await activeSource.start(config: config.captureConfig)

        schedulerTask?.cancel()
        if config.mode.usesScheduler { startSchedulerLoop() }
    }

    func stop() async {
        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil
        await glasses.stop()
        await phone.stop()
        location.stop()
        motion.stop()
        await recorder.finish()
        recordingFolder = nil
        schedulerText = "—"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Pushes server / upload / recorder / passthrough settings to the actors.
    func applySettings() async {
        await uploadQueue.configure(baseURL: config.serverURL, enabled: config.uploadEnabled)
        await pipeline.configure(
            recordToDisk: config.recordToDisk,
            upload: config.uploadEnabled,
            passthroughEveryN: config.passthroughEveryN
        )
        scheduler.tuning = config.tuning
    }

    // MARK: Hooks for other lines

    /// Kişi 2: replace the passthrough with the perception line.
    func setSink(_ sink: any FrameSink) async {
        await pipeline.setSink(sink)
    }

    /// Kişi 2: "I saw text, take another look soon" (adaptive) / high-res photo (mode B).
    func requestFollowUp() {
        if config.mode.usesScheduler {
            scheduler.requestFollowUp()
        } else {
            Task { await requestHighRes() }
        }
    }

    /// "Şimdi çek".
    func captureNow() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let frame: CapturedFrame?
        if config.mode.usesScheduler {
            frame = await activeSource.captureStill(trigger: .manual)
        } else {
            frame = await activeSource.requestHighResPhoto()
        }
        guard var frame else {
            notice = "Kare alınamadı. Kaynak hazır mı?"
            return
        }
        frame.trigger = .manual
        if config.mode.usesScheduler { scheduler.didCapture(.manual, input: makeInputs()) }
        ingest(frame)
    }

    func requestHighRes() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let frame = await activeSource.requestHighResPhoto() else {
            notice = "Yüksek çözünürlüklü fotoğraf gelmedi."
            return
        }
        ingest(frame)
    }

    /// "Son N dakikayı unut" — local side. Server side is Kişi 3's.
    func forget(minutes: Int) async {
        let removed = await uploadQueue.purge(since: Date().addingTimeInterval(TimeInterval(-60 * minutes)))
        notice = "Kuyruktan \(removed) kare silindi (son \(minutes) dk)."
    }

    // MARK: Scheduler loop

    private func startSchedulerLoop() {
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRunning else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard !isCapturing else { return }
        guard activeSource.state == .running else {
            schedulerText = "Kaynak hazır değil"
            return
        }
        if let retryNotBefore, Date() < retryNotBefore { return }

        if config.mode == .intervalPhoto {
            let due = lastFixedCapture.map { Date().timeIntervalSince($0) >= config.intervalSeconds } ?? true
            schedulerText = due ? "Çekiliyor" : "Sabit aralık \(Int(config.intervalSeconds)) sn"
            if due { await takeScheduledStill(.fixedInterval, input: nil) }
            return
        }

        let input = makeInputs()
        let decision = scheduler.decide(input)
        movement = scheduler.movement
        batteryFactor = scheduler.factor
        capturesLastMinute = scheduler.capturesLastMinute
        switch decision {
        case .wait(let why), .hold(let why):
            schedulerText = why
        case .capture(let trigger):
            schedulerText = "Çekiliyor (\(trigger.label))"
            await waitForSteadyMoment(trigger)
            await takeScheduledStill(trigger, input: input)
        }
    }

    private func takeScheduledStill(_ trigger: CaptureTrigger, input: SchedulerInputs?) async {
        isCapturing = true
        defer { isCapturing = false }
        guard let frame = await activeSource.captureStill(trigger: trigger) else {
            failedStills += 1
            let pause = min(16, pow(2, Double(failedStills - 1)))
            retryNotBefore = Date().addingTimeInterval(pause)
            schedulerText = "Kare gelmedi (\(failedStills)); \(Int(pause)) sn sonra tekrar"
            return
        }
        failedStills = 0
        retryNotBefore = nil
        if let input {
            var after = input
            after.now = Date()
            scheduler.didCapture(trigger, input: after)
            capturesLastMinute = scheduler.capturesLastMinute
        } else {
            lastFixedCapture = Date()
        }
        ingest(frame)
    }

    /// Blur gate: wait (bounded) for a calm instant between steps.
    private func waitForSteadyMoment(_ trigger: CaptureTrigger) async {
        switch trigger {
        case .dwell, .idleRefresh, .firstFrame, .manual: return
        default: break
        }
        let tuning = config.tuning
        let deadline = Date().addingTimeInterval(tuning.blurGateMaxWait)
        while Date() < deadline,
              !motion.isSteady(accelThreshold: tuning.blurAccelThreshold, rotationThreshold: tuning.blurRotationThreshold) {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func makeInputs() -> SchedulerInputs {
        let fix = location.freshFix(maxAge: 10)
        let battery = UIDevice.current.batteryLevel
        let usingGlasses = config.sourceKind == .glasses
        return SchedulerInputs(
            now: Date(),
            activity: motion.activity,
            gpsSpeed: fix?.validSpeed,
            gpsCourse: fix?.validCourse,
            gpsAccuracy: fix?.accuracy,
            odometer: location.odometer,
            stepDistance: motion.stepDistance,
            yawDegrees: motion.yawDegrees,
            phoneBattery: battery >= 0 ? Double(battery) : nil,
            phoneLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            phoneThermal: ProcessInfo.processInfo.thermalState,
            glassesBattery: usingGlasses ? glasses.device.battery : nil,
            glassesHeat: usingGlasses ? HeatLevel(glasses.device.thermal) : .normal
        )
    }

    // MARK: Ingest

    private func ingest(_ frame: CapturedFrame) {
        var frame = frame
        if let fix = location.freshFix(maxAge: 10, now: frame.capturedAt) {
            frame.latitude = fix.latitude
            frame.longitude = fix.longitude
            frame.horizontalAccuracy = fix.accuracy
            frame.headingDegrees = fix.validCourse
            frame.speedMps = fix.validSpeed
        }
        capturedCount += 1
        lastFrame = FrameSummary(
            at: frame.capturedAt,
            origin: frame.origin,
            trigger: frame.trigger,
            width: Int(frame.pixelSize.width),
            height: Int(frame.pixelSize.height),
            bytes: frame.jpeg.count,
            isHighRes: frame.isHighRes,
            hasLocation: frame.latitude != nil
        )
        let jpeg = frame.jpeg
        Task.detached(priority: .utility) { [weak self] in
            let image = UIImage(data: jpeg)?.preparingForDisplay()
            await self?.setPreview(image)
        }
        pipelineInput.yield(frame)
    }

    private func setPreview(_ image: UIImage?) {
        if let image { previewImage = image }
    }

    private func noteKept() {
        keptCount += 1
    }
}

extension HeatLevel {
    init(_ level: ThermalLevel) {
        switch level {
        case .moderate: self = .warm
        case .severe: self = .hot
        case .critical, .emergency, .shutdown: self = .critical
        default: self = .normal
        }
    }
}

extension CaptureTrigger {
    var label: String {
        switch self {
        case .stream: return "akış"
        case .firstFrame: return "ilk kare"
        case .distance: return "mesafe"
        case .heading: return "dönüş"
        case .dwell: return "durup bakma"
        case .interval: return "süre"
        case .idleRefresh: return "yenileme"
        case .fixedInterval: return "sabit aralık"
        case .followUp: return "tekrar bak"
        case .manual: return "elle"
        case .highRes: return "yüksek çözünürlük"
        }
    }
}
