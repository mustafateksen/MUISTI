import Foundation
import MWDATCore
import Observation
import UIKit

struct PipelineItem: Sendable {
    let frame: CapturedFrame
    let street: String?
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

/// The one object the UI talks to. Owns the sources, sensors, the adaptive scheduler, the
/// on-phone memory (perception → SQLite → Nemotron enrichment) and the voice assistant.
/// Single consumer of every source's `frames`.
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
    private(set) var pipelineStats = PipelineStats()
    private(set) var enrichment = EnrichmentStatus()
    private(set) var memoryCount = 0
    private(set) var pendingCount = 0
    /// Bumped whenever memories change, so lists can refresh.
    private(set) var memoryRevision = 0
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
    @ObservationIgnored let store = MemoryStore()
    @ObservationIgnored let ai: NemotronClient
    @ObservationIgnored private let worker: EnrichmentWorker
    @ObservationIgnored let queryEngine: QueryEngine
    let voice: VoiceAssistant
    @ObservationIgnored private let pipeline: MemoryPipeline
    @ObservationIgnored private let pipelineInput: AsyncStream<PipelineItem>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(config: AppConfig, wearables: WearablesController) {
        self.config = config
        self.wearables = wearables
        glasses = GlassesCaptureSource()
        phone = PhoneCameraSource()
        scheduler = AdaptiveScheduler(tuning: config.tuning)
        ai = NemotronClient(settings: config.nemotronSettings)
        worker = EnrichmentWorker(store: store, ai: ai)
        queryEngine = QueryEngine(store: store, ai: ai)
        voice = VoiceAssistant(engine: queryEngine, location: location)
        voice.localeIdentifier = config.voiceLocale
        voice.speakAnswers = config.speakAnswers
        pipeline = MemoryPipeline(recorder: recorder, store: store, worker: worker)

        let (pipelineStream, pipelineInput) = AsyncStream.makeStream(of: PipelineItem.self, bufferingPolicy: .bufferingNewest(6))
        self.pipelineInput = pipelineInput

        let pipeline = pipeline
        tasks.append(Task.detached { [weak self] in
            for await item in pipelineStream {
                let id = await pipeline.handle(item.frame, street: item.street)
                let stats = await pipeline.stats
                await self?.pipelineDidProcess(kept: id != nil, stats: stats)
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
        let enrichmentStatus = worker.statusStream
        tasks.append(Task { [weak self] in
            for await status in enrichmentStatus {
                self?.enrichment = status
                await self?.refreshCounts()
            }
        })

        location.onFix = { [recorder] fix in
            Task { await recorder.record(fix) }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.applySettings()
            await self.store.purge(olderThanDays: self.config.retentionDays)
            await self.worker.start()
            await self.refreshCounts()
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

        if let free = Self.freeDiskBytes(), free < 500_000_000 {
            notice = "Telefonda 500 MB'tan az yer var. Hafıza ve kayıt yazılamayabilir; yer aç."
        }
        if recordingFolder == nil, config.recordToDisk {
            if let free = Self.freeDiskBytes(), free < 1_000_000_000 {
                // Raw 12 MP stills are ~1.8 MB each; below 1 GB free, keep the memory but skip raw copies.
                notice = "Telefonda 1 GB'tan az yer var; ham kareler kaydedilmiyor (hafıza çalışıyor)."
                await pipeline.configure(recordRaw: false, streamEveryN: config.passthroughEveryN, zones: config.zones)
            } else {
                recordingFolder = (try? await recorder.begin())?.lastPathComponent
            }
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

    /// Pushes Nemotron / recorder / zone / voice settings to the actors.
    func applySettings() async {
        await ai.update(config.nemotronSettings)
        await pipeline.configure(recordRaw: config.recordToDisk, streamEveryN: config.passthroughEveryN, zones: config.zones)
        scheduler.tuning = config.tuning
        voice.localeIdentifier = config.voiceLocale
        voice.speakAnswers = config.speakAnswers
        await worker.signal()
    }

    // MARK: Hooks for other lines

    /// "I saw text, take another look soon" (adaptive) / high-res photo (mode B).
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

    /// "Son N dakikayı unut": deletes records and keyframes on the phone.
    func forget(minutes: Int) async {
        let removed = await store.delete(since: Date().addingTimeInterval(TimeInterval(-60 * minutes)))
        notice = "Son \(minutes) dakikadan \(removed) kayıt silindi."
        await refreshCounts()
    }

    func deleteAllMemories() async {
        let removed = await store.deleteAll()
        notice = "\(removed) kayıt silindi."
        await refreshCounts()
    }

    func deleteMemory(_ id: Int64) async {
        await store.delete(id: id)
        await refreshCounts()
    }

    func refreshCounts() async {
        let counts = await store.count()
        memoryCount = counts.total
        pendingCount = counts.pending
        memoryRevision += 1
    }

    /// Adds the current location as a 100 m no-record zone.
    func addZoneHere(name: String) -> Bool {
        guard let fix = location.latest else { return false }
        config.zones.append(NoRecordZone(name: name, latitude: fix.latitude, longitude: fix.longitude))
        Task { await applySettings() }
        return true
    }

    private func pipelineDidProcess(kept: Bool, stats: PipelineStats) {
        pipelineStats = stats
        if kept {
            keptCount += 1
            memoryCount += 1
            pendingCount += 1
            memoryRevision += 1
        }
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
            // Downsampled: a fully decoded 12 MP still would hold ~48 MB for a phone-sized view.
            let image = ImageData.thumbnail(jpeg, maxPixel: 1280).map { UIImage(cgImage: $0) }
            await self?.setPreview(image)
        }
        pipelineInput.yield(PipelineItem(frame: frame, street: location.street))
    }

    private static func freeDiskBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func setPreview(_ image: UIImage?) {
        if let image { previewImage = image }
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
