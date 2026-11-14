import AVFoundation
import Foundation
import MWDATCore
import Observation
import UIKit

struct PipelineItem: Sendable {
    let frame: CapturedFrame
    let street: String?
    var area: String? = nil
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
    @ObservationIgnored let mediaKeys = MediaKeyTrigger()
    /// Muisti Turva: the user's own safety rules over what the glasses see.
    let safety: SafetyMonitor
    /// The agent side: intents, destination, places, and what Muisti brings up by itself.
    let agent: AgentCenter
    @ObservationIgnored private let pipeline: MemoryPipeline
    @ObservationIgnored private let pipelineInput: AsyncStream<PipelineItem>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var recognizerVocabulary: [String] = []

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
        glasses.headSpeech.wakeWord = config.wakeWord.isEmpty ? "Muisti" : config.wakeWord
        voice.speakAnswers = config.speakAnswers
        pipeline = MemoryPipeline(recorder: recorder, store: store, worker: worker)
        safety = SafetyMonitor(store: SafetyStore(), ai: ai, location: location)
        agent = AgentCenter(ai: ai, memory: store, location: location, motion: motion)
        let safety = safety
        let voice = voice
        let agent = agent
        // Everything Muisti says unasked goes through one gate (`InterventionPolicy`): safety
        // warnings are always spoken, the agent's notes only when they are worth it.
        let policy = agent.policy
        policy.speak = { text, language, expectsReply, frame, urgent in
            await voice.announce(text, language: language, expectsReply: expectsReply, frame: frame, urgent: urgent,
                                 title: urgent ? nil : String(localized: "Muisti noticed"))
        }
        policy.chime = { voice.chime() }
        safety.announce = { text, language, expectsReply, frame in
            await policy.submit(Proposal(source: "safety", topic: "safety", urgency: .safety, text: text, language: language,
                                         expectsReply: expectsReply, frame: frame))
        }
        agent.language = { voice.localeIdentifier }
        voice.safetyHandler = { command in
            // A yes/no or "not now" may answer something the agent asked or brought up.
            switch command {
            case .confirm: if let reply = await agent.resolvePending(true) { return reply }
            case .cancel: if let reply = await agent.resolvePending(false) { return reply }
            case .snooze: if let reply = await agent.snoozeLast() { return reply }
            default: break
            }
            return await safety.handle(command)
        }
        voice.agentHandler = { command in await agent.handle(command) }
        safety.autoHazards = { config.safetyAuto }
        let enrichment = worker
        let memoryPipeline = pipeline
        Task {
            await enrichment.setOnEnriched { id, title, passage, vector, frame in
                await safety.checkEnriched(recordID: id, title: title, passage: passage, vector: vector, frame: frame)
            }
            await enrichment.setOnNoticed { noticed in await agent.noticed(noticed) }
            await memoryPipeline.setOnTextStored { id, text, frame in
                await safety.checkText(recordID: id, text: text, frame: frame)
            }
        }
        // Hands-free questions through the glasses mic (on-glasses transcription).
        let headSpeech = glasses.headSpeech
        headSpeech.onQuestion = { question in Task { await voice.askFromGlasses(question) } }
        headSpeech.isBusy = { voice.isBusy }
        headSpeech.onWake = { voice.acknowledge() }
        // Push-to-talk: a tap on the glasses' touchpad, reported by the SDK or as a media key.
        let mediaKeys = mediaKeys
        mediaKeys.onTap = { Task { await voice.pushToTalk() } }
        glasses.buttons.onPress = {
            guard !mediaKeys.recentlyTapped else { return }
            mediaKeys.noteTap()
            Log.glasses.info("double tap on the side (glasses inputs): ask")
            Task { await voice.pushToTalk() }
        }
        voice.glassesListening = { headSpeech.isListening }
        voice.expectGlassesReply = { headSpeech.expectReply() }
        glasses.wantsSpeech = { [weak wearables] in
            config.handsFree && wearables?.microphonePermission == .granted
        }
        glasses.wantsStreamAudio = { [weak wearables] in
            GlassesCaptureSource.usesWiFiTransport && wearables?.microphonePermission == .granted
        }
        voice.glassesMic = glasses.micTap
        glasses.prepareSpeech = { [weak wearables] in
            guard let wearables, config.handsFree || GlassesCaptureSource.usesWiFiTransport else { return }
            // The phone recogniser (wake listening on the glasses audio) needs Speech access.
            _ = await VoiceAssistant.requestSpeechAuthorization()
            let status = await wearables.refreshMicrophonePermission()
            // Not allowed yet: ask once by itself (Meta AI opens, shows the prompt, comes back).
            // After a "no", only the Settings button asks again.
            let key = "askedGlassesMicrophone"
            if status != .granted, !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                Log.glasses.info("asking for the glasses microphone permission")
                _ = await wearables.requestMicrophonePermission()
            }
        }
        let memoryStore = store
        voice.vocabulary = {
            let seen = await memoryStore.vocabulary(limit: 90)
            let watched = safety.watched.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            return Array(Set(watched)) + seen
        }
        voice.warmUp()
        let safetyStore = safety.store
        let bridge = SafetyBridge(
            context: {
                let rules = await safety.promptContext()
                let notes = await agent.promptContext()
                return rules + "\n\n" + notes
            },
            forget: { since in
                await safetyStore.delete(since: since)
                await agent.forget(since: since)
            },
            frames: { ids in await safety.frames(forEvents: ids) }
        )
        let engine = queryEngine
        Task { await engine.setSafety(bridge) }

        let (pipelineStream, pipelineInput) = AsyncStream.makeStream(of: PipelineItem.self, bufferingPolicy: .bufferingNewest(6))
        self.pipelineInput = pipelineInput
        agent.isCapturing = { [weak self] in self?.isRunning ?? false }

        let pipeline = pipeline
        tasks.append(Task.detached { [weak self] in
            for await item in pipelineStream {
                let id = await pipeline.handle(item.frame, street: item.street, area: item.area)
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

        let locationProvider = location
        location.onFix = { [recorder] fix in
            locationProvider.remember(fix)
            Task { await recorder.record(fix) }
        }
        // Glasses video recorded while Muisti was in the background → frames → pipeline.
        let segments = glasses.backgroundSegments
        tasks.append(Task { [weak self] in
            for await segment in segments { await self?.ingestBackgroundSegment(segment) }
        })
        Task { [weak self] in
            guard let self else { return }
            await self.store.purge(olderThanDays: self.config.retentionDays)
            await self.agent.purge(retentionDays: self.config.retentionDays)
            await self.store.assignMissingEpisodes()
            await self.refreshCounts()
            await self.applySettings()
            await self.worker.start()
            // Ask for Local Network early: without it the glasses send photos over Bluetooth.
            if self.config.sourceKind == .glasses { LocalNetworkPermission.shared.check() }
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.autoStartIfReady()
            }
        })
        glasses.wakeStrings = { [weak self] in
            let wake = config.wakeWord.isEmpty ? "Muisti" : config.wakeWord
            return [wake, "Hey \(wake)"] + config.wakeAliases + (self?.recognizerVocabulary ?? [])
        }
        // Names seen (signs, booths, streets) for the phone recogniser on the glasses audio, so
        // "Arduino" is not heard as "audio"; refreshed every minute as memory grows.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seen = await self.store.vocabulary(limit: 90)
                let watched = self.safety.watched.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
                self.recognizerVocabulary = Array(Set(watched)) + seen
                self.glasses.audioWake.updateStrings(self.glasses.wakeStrings())
                try? await Task.sleep(for: .seconds(60))
            }
        })
        // Tool for the answer model: what the glasses see right now (faces masked), also kept.
        let engineForLive = queryEngine
        Task { [weak self] in
            await engineForLive.setLiveView { [weak self] in
                await self?.liveView()
            }
        }
        // Short press of the glasses' capture button (Meta takes its photo): keep this moment.
        glasses.buttons.onCapture = { [weak self] in Task { await self?.captureNow() } }
        Task.detached(priority: .utility) { PerceptionEngine.warmUpModels() }
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
        schedulerTask?.cancel()
    }

    // MARK: Start / stop

    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var autoStarting = false

    /// Capture starts by itself once the glasses are connected (foreground, glasses source).
    /// A manual Stop holds it off until the glasses disconnect and connect again.
    private func autoStartIfReady() async {
        let connected = glasses.hasActiveDevice && glasses.device.link == .connected
        guard connected else {
            stoppedByUser = false
            return
        }
        guard config.autoStart, config.sourceKind == .glasses, !isRunning, !stoppedByUser, !autoStarting,
              UIApplication.shared.applicationState == .active else { return }
        autoStarting = true
        defer { autoStarting = false }
        Log.pipeline.info("glasses connected: starting capture automatically")
        await start()
    }

    func start() async {
        notice = nil
        LocalNetworkPermission.shared.check()
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true   // backgrounding ends the glasses session
        UIDevice.current.isBatteryMonitoringEnabled = true
        await applySettings()

        if let free = Self.freeDiskBytes(), free < 500_000_000 {
            notice = String(localized: "Less than 500 MB free on your iPhone. Memories and recordings may not be saved; free up space.")
        }
        if recordingFolder == nil, config.recordToDisk {
            if let free = Self.freeDiskBytes(), free < 1_000_000_000 {
                // Raw 12 MP stills are ~1.8 MB each; below 1 GB free, keep the memory but skip raw copies.
                notice = String(localized: "Less than 1 GB free on your iPhone; raw frames aren't being saved (memory still works).")
                await pipeline.configure(recordRaw: false, streamEveryN: config.passthroughEveryN, zones: config.zones)
            } else {
                recordingFolder = (try? await recorder.begin())?.lastPathComponent
            }
        }
        location.start()
        if config.mode.usesScheduler { motion.start() }
        if config.sourceKind == .glasses {
            AudioKeepAlive.start()   // lets push-to-talk use the microphone while the phone is locked
            mediaKeys.activate()
        }

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
        stoppedByUser = true   // no auto-start until the glasses disconnect and come back
        schedulerTask?.cancel()
        schedulerTask = nil
        await glasses.stop()
        await phone.stop()
        location.stop()
        motion.stop()
        mediaKeys.deactivate()
        AudioKeepAlive.stop()
        await recorder.finish()
        recordingFolder = nil
        schedulerText = "—"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Pushes Nemotron / recorder / zone / voice settings to the actors.
    func applySettings() async {
        await ai.update(config.nemotronSettings)
        await store.useEmbeddingModel(config.nemotronSettings.embedModel)
        await pipeline.configure(recordRaw: config.recordToDisk, streamEveryN: config.passthroughEveryN, zones: config.zones)
        scheduler.tuning = config.tuning
        voice.localeIdentifier = config.voiceLocale
        voice.speakAnswers = config.speakAnswers
        glasses.headSpeech.wakeWord = config.wakeWord.isEmpty ? "Muisti" : config.wakeWord
        glasses.headSpeech.aliases = config.wakeAliases
        glasses.refreshSpeech()
        // Talking to Muisti uses the glasses mic (Bluetooth HFP). Only when the camera itself
        // runs over Bluetooth Classic would HFP share the radio and stall it: phone mic then.
        // Over Wi-Fi (the default now) the camera has its own link.
        voice.prefersGlassesMic = { [weak self] in
            guard let self else { return true }
            return !(self.isRunning && self.config.sourceKind == .glasses && !GlassesCaptureSource.usesWiFiTransport)
        }
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

    /// "Capture now".
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
            notice = String(localized: "Couldn't get a frame. Is the source ready?")
            return
        }
        frame.trigger = .manual
        if config.mode.usesScheduler { scheduler.didCapture(.manual, input: makeInputs()) }
        ingest(frame)
    }

    /// The newest frame from the active camera, faces masked, with its OCR (answer tool).
    /// The frame is also remembered like a manual capture.
    func liveView() async -> (jpeg: Data, ocr: String, at: Date)? {
        var live = isRunning ? await activeSource.captureStill(trigger: .manual) : nil
        if live == nil, isRunning, config.sourceKind == .glasses {
            // Nothing decoded (the phone is locked and iOS gives no video decoder there): ask
            // the glasses for a photo through the running stream. The user asked to look, so
            // the capture sound is fine here.
            live = await activeSource.requestHighResPhoto()
            Trace.note("live view: stream photo \(live == nil ? "failed" : "ok")")
        }
        if var frame = live {
            frame.trigger = .manual
            ingest(frame)
            let jpeg = frame.jpeg
            if let copy = await Task.detached(priority: .userInitiated, operation: { SafetyFrame.prepare(jpeg, maxPixel: 1536) }).value {
                return (copy.jpeg, copy.ocr, frame.capturedAt)
            }
            Log.pipeline.info("live view: privacy copy failed")
        } else {
            Log.pipeline.info("live view: no live frame (running \(self.isRunning), source \(String(describing: self.activeSource.state), privacy: .public))")
        }
        // No live frame (stream paused, phone in a pocket): the newest kept frame, if recent.
        // Its time goes to the model, so it is not presented as "right now".
        // Only a few seconds old: an older frame passed off as the live view showed the user the
        // last picture from before the phone was locked (field 14 Nov).
        guard let newest = await store.recent(limit: 1).first, Date().timeIntervalSince(newest.seenAt) < 15,
              let jpeg = try? Data(contentsOf: store.frameURL(newest)) else { return nil }
        Log.pipeline.info("live view: using the newest kept frame (\(Int(Date().timeIntervalSince(newest.seenAt))) s old)")
        return (jpeg, newest.ocrText, newest.seenAt)
    }

    func requestHighRes() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let frame = await activeSource.requestHighResPhoto() else {
            notice = String(localized: "No high-resolution photo arrived.")
            return
        }
        ingest(frame)
    }

    /// "Forget the last N minutes": deletes records and keyframes on the phone.
    func forget(minutes: Int) async {
        let since = Date().addingTimeInterval(TimeInterval(-60 * minutes))
        let removed = await store.delete(since: since)
        await safety.forget(since: since)
        await agent.forget(since: since)
        notice = String(localized: "Deleted \(removed) records from the last \(minutes) minutes.")
        await refreshCounts()
    }

    func deleteAllMemories() async {
        let removed = await store.deleteAll()
        await safety.store.deleteAll()
        await safety.reload()
        await agent.deleteAll()
        notice = String(localized: "Deleted \(removed) records.")
        await refreshCounts()
    }

    func deleteMemory(_ id: Int64) async {
        await store.delete(id: id)
        await refreshCounts()
    }

    /// Frames from a background recording, every `step` seconds, through the normal pipeline
    /// with their real time and the nearest GPS fix. Dedup drops the repeats. File deleted after.
    private func ingestBackgroundSegment(_ segment: BackgroundSegment, step: Double = 2.5) async {
        let asset = AVURLAsset(url: segment.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2400, height: 2400)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var kept = 0, sampled = 0
        var t = 0.0
        while t <= segment.duration {
            defer { t += step }
            guard let (image, actual) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                  let jpeg = ImageData.encodeJPEG(image, quality: 0.85) else { continue }
            sampled += 1
            let at = segment.startedAt.addingTimeInterval(actual.seconds)
            var frame = CapturedFrame(capturedAt: at, origin: .glassesStream, jpeg: jpeg,
                                      pixelSize: CGSize(width: image.width, height: image.height),
                                      isHighRes: false, trigger: .interval)
            if let fix = location.fix(near: at) {
                frame.latitude = fix.latitude
                frame.longitude = fix.longitude
                frame.horizontalAccuracy = fix.accuracy
                frame.speedMps = fix.validSpeed
                frame.headingDegrees = fix.validCourse
            }
            if await pipeline.handle(frame, street: nil) != nil { kept += 1 }
        }
        try? FileManager.default.removeItem(at: segment.url)
        Log.pipeline.info("background segment \(Int(segment.duration)) s: \(sampled) frames sampled, \(kept) kept")
        await refreshCounts()
    }

    #if DEBUG
    /// Test data: feeds photos from `Documents/<folder>/manifest.json`
    /// (`[{"file","seen_at" ISO-8601,"lat","lon","street"}]`) through the real pipeline (OCR,
    /// head/plate masking, dedup, episodes, Nemotron), as if the glasses had taken them then.
    func ingestFolder(_ folder: String) async -> Int {
        struct Entry: Decodable { let file: String; let seen_at: String; let lat: Double?; let lon: Double?; let street: String? }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            Log.pipeline.error("ingest: no manifest in \(dir.path, privacy: .public)")
            return 0
        }
        var kept = 0
        var ids: [String: Int64] = [:]
        for entry in entries.sorted(by: { $0.seen_at < $1.seen_at }) {
            guard let raw = try? Data(contentsOf: dir.appendingPathComponent(entry.file)),
                  let jpeg = ImageData.ensureJPEG(raw),
                  let date = ISO8601.date(from: entry.seen_at) else {
                Log.pipeline.error("ingest: skipped \(entry.file, privacy: .public)")
                continue
            }
            var frame = CapturedFrame(capturedAt: date, origin: .glassesPhoto, jpeg: jpeg,
                                      pixelSize: ImageData.pixelSize(of: jpeg), isHighRes: true, trigger: .manual)
            frame.latitude = entry.lat
            frame.longitude = entry.lon
            frame.horizontalAccuracy = 10
            let before = await pipeline.stats.dropped
            let id = await pipeline.handle(frame, street: entry.street)
            if id == nil {
                let after = await pipeline.stats.dropped
                let reasons = after.filter { before[$0.key, default: 0] < $0.value }.map { "\($0.key)" }
                Log.pipeline.info("ingest \(entry.file, privacy: .public) dropped: \(reasons.joined(separator: ","), privacy: .public)")
            }
            if let id { kept += 1; ids[entry.file] = id }
            Log.pipeline.info("ingest \(entry.file, privacy: .public) → \(id.map(String.init) ?? "dropped", privacy: .public)")
        }
        if let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: dir.appendingPathComponent("ids.json"))
        }
        await refreshCounts()
        return kept
    }
    #endif

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
            glasses.noteKeptFrame()
            if Trace.inBackground { Trace.note("kept a memory while locked") }
        }
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
            schedulerText = String(localized: "Source not ready")
            return
        }
        if let retryNotBefore, Date() < retryNotBefore { return }

        if config.mode == .intervalPhoto {
            let due = lastFixedCapture.map { Date().timeIntervalSince($0) >= config.intervalSeconds } ?? true
            schedulerText = due ? String(localized: "Capturing") : String(localized: "Fixed interval \(Int(config.intervalSeconds)) s")
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
            guard !glasses.recordingInBackground || glasses.decodesLive else {
                schedulerText = String(localized: "Recording in background (glasses stream saved to file)")
                return
            }
            schedulerText = String(localized: "Capturing (\(trigger.label))")
            await waitForSteadyMoment(trigger)
            await takeScheduledStill(trigger, input: input)
        }
    }

    private func takeScheduledStill(_ trigger: CaptureTrigger, input: SchedulerInputs?) async {
        isCapturing = true
        defer { isCapturing = false }
        guard let frame = await activeSource.captureStill(trigger: trigger) else {
            failedStills += 1
            // A stream that hiccups recovers in seconds: in stream-frame mode never wait long.
            let cap: Double = config.mode.picksStreamFrames ? 2 : 16
            let pause = min(cap, pow(2, Double(failedStills - 1)))
            retryNotBefore = Date().addingTimeInterval(pause)
            schedulerText = String(localized: "No frame (\(failedStills)); retrying in \(Int(pause)) s")
            return
        }
        failedStills = 0
        retryNotBefore = nil
        Log.scheduler.info("still \(trigger.rawValue, privacy: .public) \(Int(frame.pixelSize.width))x\(Int(frame.pixelSize.height)) age \(Int(Date().timeIntervalSince(frame.capturedAt) * 1000)) ms · \(self.scheduler.movement.rawValue, privacy: .public) head \(self.glasses.headMotion.isLive ? String(format: "%.2f rad/s %.3f g", self.glasses.headMotion.rotation, self.glasses.headMotion.energy) : "off", privacy: .public)")
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
        // The camera is on the head: its IMU decides when it can, the phone otherwise.
        func steady() -> Bool {
            let head = glasses.headMotion
            if config.sourceKind == .glasses, head.isLive {
                return head.isSteady(rotationThreshold: tuning.blurRotationThreshold / 2, accelThreshold: tuning.blurAccelThreshold)
            }
            return motion.isSteady(accelThreshold: tuning.blurAccelThreshold, rotationThreshold: tuning.blurRotationThreshold)
        }
        while Date() < deadline, !steady() {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func makeInputs() -> SchedulerInputs {
        let fix = location.freshFix(maxAge: 10)
        let battery = UIDevice.current.batteryLevel
        let usingGlasses = config.sourceKind == .glasses
        let head = usingGlasses && glasses.headMotion.isLive ? glasses.headMotion : nil
        return SchedulerInputs(
            now: Date(),
            activity: motion.activity,
            gpsSpeed: fix?.validSpeed,
            gpsCourse: fix?.validCourse,
            gpsAccuracy: fix?.accuracy,
            odometer: location.odometer,
            stepDistance: motion.stepDistance,
            yawDegrees: motion.yawDegrees,
            headOrientation: head?.orientation,
            headRotation: head?.rotation,
            headEnergy: head?.energy,
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
        // GPS at the moment the picture was taken (photos can arrive 10+ s later).
        if let fix = location.fix(near: frame.capturedAt) ?? location.freshFix(maxAge: 10, now: frame.capturedAt) {
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
        pipelineInput.yield(PipelineItem(frame: frame, street: location.street,
                                         area: location.areaText(for: location.fix(near: frame.capturedAt))))
        // Safety rules look at every frame (duplicates included: a stove frame looks the same).
        safety.consider(frame)
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
        case .stream: return String(localized: "stream", comment: "Capture trigger")
        case .firstFrame: return String(localized: "first frame", comment: "Capture trigger")
        case .distance: return String(localized: "distance", comment: "Capture trigger")
        case .heading: return String(localized: "turn", comment: "Capture trigger: the wearer turned")
        case .dwell: return String(localized: "dwell", comment: "Capture trigger: the wearer stopped moving")
        case .interval: return String(localized: "time", comment: "Capture trigger: time interval elapsed")
        case .idleRefresh: return String(localized: "refresh", comment: "Capture trigger")
        case .fixedInterval: return String(localized: "fixed interval", comment: "Capture trigger")
        case .followUp: return String(localized: "follow-up", comment: "Capture trigger")
        case .manual: return String(localized: "manual", comment: "Capture trigger")
        case .highRes: return String(localized: "high-res", comment: "Capture trigger")
        }
    }
}
