import CoreGraphics
import Foundation
import MWDATCamera
import MWDATCore
import NetworkExtension
import Observation
import UIKit
import os

/// Live snapshot of the active glasses (battery, worn, hinge, heat).
struct GlassesDeviceStatus: Equatable, Sendable {
    var name: String = ""
    var link: LinkState = .disconnected
    var battery: Int?
    var charging: ChargingState = .unknown
    var don: DonState = .unknown
    var hinge: HingeState = .unknown
    var thermal: ThermalLevel = .unknown
}

/// Real glasses and MockDeviceKit glasses, through the same SDK calls.
///
/// Lifecycle: `DeviceSession` → `Camera` → either
/// - a stream (modes A/B): `.raw` frames are JPEG-encoded off the main thread and yielded on `frames`, or
/// - the photo capability (adaptive / C): the stream is started only to wake the sensor
///   (`Photo.start()` on a cold camera never leaves `starting`), the photo capability is
///   started once frames flow, then the stream is put down. From then on the camera is idle
///   until `captureStill` asks for one photo. No continuous video crosses Bluetooth.
///
/// The SDK's own `DeviceSessionState` / `StreamState` / `PhotoState` are mirrored and the
/// user-facing `CaptureState` is derived from them in one place (`recompute()`).
@Observable
@MainActor
final class GlassesCaptureSource: CaptureSource {
    let kind: SourceKind = .glasses

    private(set) var state: CaptureState = .idle {
        didSet { if state != oldValue { stateContinuation.yield(state) } }
    }
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped
    private(set) var photoState: PhotoState = .stopped
    private(set) var hasActiveDevice = false
    private(set) var device = GlassesDeviceStatus()
    private(set) var lastError: String?
    private(set) var needsGlassesAppUpdate = false
    private(set) var isCapturingStill = false
    /// Last photo's Bluetooth transfer time. Expect ~1 s, sometimes ~9 s.
    private(set) var lastTransferMillis: Int?
    private(set) var transferFraction: Double?

    @ObservationIgnored let frames: AsyncStream<CapturedFrame>
    @ObservationIgnored let states: AsyncStream<CaptureState>
    @ObservationIgnored private let frameContinuation: AsyncStream<CapturedFrame>.Continuation
    @ObservationIgnored private let stateContinuation: AsyncStream<CaptureState>.Continuation

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let selector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    /// Head IMU from the glasses (10 Hz) while a session runs; drives the adaptive scheduler.
    @ObservationIgnored let headMotion = GlassesMotion()
    /// Hands-free voice: on-glasses transcription (text only over the link).
    @ObservationIgnored let headSpeech = GlassesSpeech()
    /// Capture / action button on the glasses = push-to-talk.
    @ObservationIgnored let buttons = GlassesInputs()
    /// Siri-like wake listening on the phone over the glasses mic's streamed audio.
    @ObservationIgnored let audioWake = GlassesAudioRecognizer()
    /// Words the phone recogniser should expect (wake word, its spellings, names in memory).
    @ObservationIgnored var wakeStrings: () -> [String] = { [] }
    /// Set when the glasses refused audio streaming: video only from then on.
    @ObservationIgnored private var audioDisabled = false
    /// Recent stream errors while audio was on (two within 3 minutes → video only).
    @ObservationIgnored private var audioStreamErrors: [Date] = []
    private var streamsAudio: Bool { (wantsSpeech() || wantsStreamAudio()) && !audioDisabled && !MockRuntime.isActive }
    /// The glasses mic inside the camera stream, for push-to-talk (see `GlassesMicTap`).
    let micTap = GlassesMicTap()
    /// Carry the glasses mic in the stream for push-to-talk (Wi-Fi link + Meta mic permission).
    @ObservationIgnored var wantsStreamAudio: () -> Bool = { false }
    /// Whether to start glasses speech with a session (setting + microphone permission).
    @ObservationIgnored var wantsSpeech: () -> Bool = { false }
    /// Re-reads the glasses microphone permission (it cannot be read before a device is there).
    @ObservationIgnored var prepareSpeech: () async -> Void = {}

    /// Settings or the microphone permission changed: start or stop glasses speech now.
    func refreshSpeech() {
        guard let session, session.state == .started else { return }
        if wantsSpeech() {
            headSpeech.attach(to: session)
        } else {
            headSpeech.detach()
        }
    }
    /// Newest stream frame and when it arrived (adaptive mode); written off the main actor.
    @ObservationIgnored private let latestFrame = OSAllocatedUnfairLock<(VideoFrame, Date)?>(initialState: nil)
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var config: CaptureConfig?

    @ObservationIgnored private var wantRunning = false
    /// Blocks everything until the user acts: registration, permission, fatal error.
    @ObservationIgnored private var blocked: CaptureState?
    @ObservationIgnored private var backgroundPaused = false
    @ObservationIgnored private var suppressErrorsUntil: Date?

    /// Camera permission was confirmed `.granted` (a check before any device was discovered
    /// cannot answer, so it is repeated once the glasses appear).
    @ObservationIgnored private var permissionVerified = false
    @ObservationIgnored private var wakeStreamStopIntended = false
    @ObservationIgnored private var photoStartRequested = false
    @ObservationIgnored private var cameraEverStarted = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reattachAttempts = 0
    /// The current attempt failed on the Wi-Fi link: start the next one from a clean slate.
    @ObservationIgnored private var linkFailed = false
    @ObservationIgnored private var streamWatchdog: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    @ObservationIgnored private let sessionTokens = ListenerTokenBag()
    @ObservationIgnored private let cameraTokens = ListenerTokenBag()
    @ObservationIgnored private var deviceStateToken: (any AnyListenerToken)?
    @ObservationIgnored private var observedDeviceId: DeviceIdentifier?

    /// When the photo capability last reported `.started`; the sensor needs a beat after the
    /// wake-up stream is put down before a still is accepted.
    @ObservationIgnored private var photoReadyAt: Date?
    /// Resolutions that failed repeatedly on this device; the next lower one is tried instead.
    @ObservationIgnored private var failedResolutions: Set<PhotoResolution> = []
    /// Consecutive fast failures per resolution. Three in a row = treat as unsupported.
    @ObservationIgnored private var fastFailures: [PhotoResolution: Int] = [:]
    @ObservationIgnored private let pendingPhoto = OneShot<Data>()
    @ObservationIgnored private let pendingStreamPhoto = OneShot<Data>()
    @ObservationIgnored private let encoder = StreamFrameEncoder()

    @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    /// True while the app is in the background and the glasses' HEVC stream is being written
    /// to a file (see `BackgroundSegmentRecorder`).
    private(set) var recordingInBackground = false
    @ObservationIgnored private var backgroundRecorder: BackgroundSegmentRecorder?
    /// Adaptive mode over Wi-Fi: one `.hvc1` stream for foreground (decoded here) and
    /// background (written to a file) so locking the phone does not rebuild the camera and
    /// drop the glasses' Wi-Fi link. See `HEVCFrameDecoder`.
    @ObservationIgnored let hevc = HEVCFrameDecoder()
    @ObservationIgnored private var compressedLive = false
    /// `.hvc1` produced no picture on this phone: `.raw` from then on.
    @ObservationIgnored private var hevcFallback = false
    @ObservationIgnored private let liveRecorder = OSAllocatedUnfairLock<BackgroundSegmentRecorder?>(initialState: nil)
    @ObservationIgnored private var hevcCheck: Task<Void, Never>?
    /// Memories kept from live frames while the phone was locked.
    @ObservationIgnored private var backgroundKept = 0

    /// Frames come from the decoded stream (foreground and, if iOS allows, background).
    var decodesLive: Bool { compressedLive && camera != nil }

    /// The pipeline kept a frame (called by the controller).
    func noteKeptFrame() {
        if recordingInBackground { backgroundKept += 1 }
    }
    /// Finished background recordings, for the controller to run through the pipeline.
    @ObservationIgnored let backgroundSegments: AsyncStream<BackgroundSegment>
    @ObservationIgnored private let segmentContinuation: AsyncStream<BackgroundSegment>.Continuation

    private static let photoTimeout: Duration = .seconds(25)

    /// The SDK picks the transport from Info.plist: with the ExternalAccessory protocol it uses
    /// Bluetooth Classic only (Meta, issue #356); without it, the glasses' own Wi-Fi (SoftAP).
    static let usesWiFiTransport: Bool =
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") == nil   // field: first 12 MP still took 13–15 s

    init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        selector = AutoDeviceSelector(wearables: wearables)
        (frames, frameContinuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(2))
        (backgroundSegments, segmentContinuation) = AsyncStream.makeStream(of: BackgroundSegment.self)
        (states, stateContinuation) = AsyncStream.makeStream(of: CaptureState.self, bufferingPolicy: .bufferingNewest(8))
        hasActiveDevice = selector.activeDevice != nil
        startDeviceMonitoring()
        startBackgroundMonitoring()
    }

    isolated deinit {
        deviceMonitorTask?.cancel()
        backgroundTask?.cancel()
        reconnectTask?.cancel()
        session?.stop()
    }

    /// What the user should do while we wait for the glasses (brief §7: one next step).
    var waitingHint: String {
        guard hasActiveDevice else {
            return String(localized: "Turn on your glasses, unfold them and keep them near your iPhone.")
        }
        if device.hinge == .closed { return String(localized: "Glasses are folded. Unfold them to start a new session.") }
        if device.don == .doffed { return String(localized: "Glasses aren't on. Put them on to reconnect.") }
        if device.link != .connected { return String(localized: "Connecting to glasses…") }
        if config?.autoReconnect == true, reconnectAttempts >= 3 {
            return String(localized: "Couldn't connect yet. Trying again…")
        }
        return String(localized: "Reconnecting to glasses…")
    }

    /// Battery / heat warning derived from device state (brief §7). The SDK also reports
    /// `StreamError.batteryLow/.thermalHot`, but those arrive only once the device acts.
    /// Recent photo transfer speeds (bytes/s). Wi-Fi moves a 12 MP still in about a second;
    /// Bluetooth Classic needs 10+ s, which means the SDK's Wi-Fi link is not up.
    @ObservationIgnored private var recentThroughput: [Double] = []
    private(set) var slowLink = false

    private func noteThroughput(bytes: Int, millis: Int) {
        guard bytes > 200_000, millis > 0, !MockRuntime.isActive else { return }
        recentThroughput.append(Double(bytes) / (Double(millis) / 1000))
        recentThroughput = Array(recentThroughput.suffix(3))
        // Two of the last three under 400 KB/s: Bluetooth.
        slowLink = recentThroughput.filter { $0 < 400_000 }.count >= 2
        if slowLink { Log.glasses.info("slow photo link: \(self.recentThroughput.map { Int($0 / 1000) }, privacy: .public) KB/s") }
    }

    var healthWarning: String? {
        guard hasActiveDevice else { return nil }
        if LocalNetworkPermission.shared.denied {
            return String(localized: "Local Network is off for Muisti, so the glasses send photos over slow Bluetooth. Turn it on in Settings › Privacy & Security › Local Network.")
        }
        if slowLink {
            return String(localized: "Photos arrive slowly over Bluetooth. Turn on the phone's Wi-Fi and allow Local Network for Muisti (Settings › Privacy & Security › Local Network) so the glasses can use Wi-Fi.")
        }
        let suggestion = usesPhoto ? "" : String(localized: " Switching to adaptive mode saves battery and reduces heat.", comment: "Appended after a glasses warning; keep the leading space")
        switch device.thermal {
        case .critical, .emergency, .shutdown:
            return String(localized: "Glasses are too hot; capture paused. Let them cool down.")
        case .severe:
            return String(localized: "Glasses are warming up; capturing less often.") + suggestion
        default:
            break
        }
        if let battery = device.battery, battery < 15, device.charging != .charging {
            return String(localized: "Glasses battery low (\(battery)%); capturing less often.") + suggestion
        }
        return nil
    }

    private var usesPhoto: Bool { config?.mode.usesPhotoCapability ?? false }
    private var streamOrigin: CaptureOrigin { MockRuntime.isActive ? .mockDevice : .glassesStream }
    private var photoOrigin: CaptureOrigin { MockRuntime.isActive ? .mockDevice : .glassesPhoto }

    // MARK: - CaptureSource

    func start(config: CaptureConfig) async {
        if wantRunning, session != nil, blocked == nil, !backgroundPaused, self.config == config {
            return
        }
        if session != nil, self.config != config {
            // Mode or stream settings changed: rebuild the camera on a fresh session.
            await stop()
        }
        self.config = config
        wantRunning = true
        blocked = nil
        backgroundPaused = false
        lastError = nil
        reconnectAttempts = 0
        reattachAttempts = 0
        if linkFailed { Self.forgetGlassesWiFi() }
        audioDisabled = false   // a new recording tries the glasses mic audio again
        audioStreamErrors = []

        guard wearables.registrationState == .registered else {
            blocked = .needsRegistration
            recompute()
            return
        }

        if !permissionVerified {
            switch await checkCameraPermission() {
            case .granted: permissionVerified = true
            case .denied:
                blocked = .needsPermission
                recompute()
                return
            case .unknown:
                // No connected device to ask yet. Not a denial: ask again when it appears.
                break
            }
        }

        if session == nil, hasActiveDevice {
            await startSessionIfAllowed()
        }
        recompute()
    }

    private enum PermissionAnswer { case granted, denied, unknown }

    private func checkCameraPermission() async -> PermissionAnswer {
        do {
            return try await wearables.checkPermissionStatus(.camera) == .granted ? .granted : .denied
        } catch {
            Log.glasses.info("permission check deferred: \(error.description, privacy: .public)")
            return .unknown
        }
    }

    /// Starts a session, first confirming camera permission if that was not possible earlier.
    private func startSessionIfAllowed() async {
        if !permissionVerified {
            switch await checkCameraPermission() {
            case .granted:
                permissionVerified = true
            case .denied:
                blocked = .needsPermission
                recompute()
                return
            case .unknown:
                break   // still unanswerable: try; the stream reports `.permissionDenied` if so
            }
        }
        guard wantRunning, session == nil, blocked == nil else { return }
        startSession()
    }

    /// Call after the user confirmed the switch to Meta AI.
    func requestPermissionAndStart(using controller: WearablesController) async {
        guard let config else { return }
        if await controller.requestCameraPermission() {
            permissionVerified = true
            blocked = nil
            await start(config: config)
        } else {
            blocked = .needsPermission
            recompute()
        }
    }

    func stop() async {
        wantRunning = false
        blocked = nil
        lastError = nil
        backgroundPaused = false
        if recordingInBackground {
            recordingInBackground = false
            await finishBackgroundRecording()
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingPhoto.fulfill(nil)
        pendingStreamPhoto.fulfill(nil)
        if let camera { camera.stop() }     // cascades to stream and photo
        if let session {
            session.stop()                  // `.stopped` arrives later and cleans up
        }
        recompute()
    }

    func captureStill(trigger: CaptureTrigger) async -> CapturedFrame? {
        // Background: frames come from the running HEVC stream if the phone decodes them there;
        // otherwise the stream is only recorded to a file.
        guard !recordingInBackground || compressedLive else { return nil }
        guard let config else { return nil }
        // Silent: a stream photo plays the glasses' capture chime every time.
        if config.mode.picksStreamFrames { return await newestStreamFrame(trigger: trigger) }
        guard usesPhoto else { return nil }   // stream modes deliver through `frames`
        return await takePhoto(
            resolution: config.stillResolution.sdk,
            quality: config.stillQuality.sdk,
            trigger: trigger
        )
    }

    /// Newest frame of the running stream (adaptive mode): no transfer wait. Waits up to 2 s
    /// for one that is less than a second old.
    private func newestStreamFrame(trigger: CaptureTrigger) async -> CapturedFrame? {
        // A look on request (live view, "capture now") takes any frame from the last 3 s and
        // leaves it for the scheduler; scheduled stills want a new frame each time.
        let manual = trigger == .manual
        let maxAge: TimeInterval = manual ? 3 : 1
        let deadline = Date().addingTimeInterval(manual ? 3 : 2)
        if compressedLive { return await newestDecodedFrame(trigger: trigger, maxAge: maxAge, deadline: deadline) }
        var picked: (VideoFrame, Date)?
        while picked == nil, Date() < deadline {
            if streamState == .streaming, let latest = latestFrame.withLock({ $0 }),
               Date().timeIntervalSince(latest.1) < maxAge {
                picked = latest
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let (frame, at) = picked, device.don != .doffed else {
            Log.glasses.info("no stream frame (\(trigger.rawValue, privacy: .public)): stream \(String(describing: self.streamState), privacy: .public), don \(String(describing: self.device.don), privacy: .public)")
            return nil
        }
        if !manual { latestFrame.withLock { $0 = nil } }   // the next scheduled still must be a new frame
        let origin = streamOrigin
        return await Task.detached(priority: .userInitiated) { () -> CapturedFrame? in
            guard let image = frame.makeUIImage(), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
            let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            return CapturedFrame(capturedAt: at, origin: origin, jpeg: jpeg, pixelSize: size, isHighRes: false, trigger: trigger)
        }.value
    }

    private func newestDecodedFrame(trigger: CaptureTrigger, maxAge: TimeInterval, deadline: Date) async -> CapturedFrame? {
        let manual = trigger == .manual
        var picked: DecodedFrame?
        while picked == nil, Date() < deadline {
            if streamState == .streaming, let frame = hevc.newest(maxAge: maxAge, take: !manual) {
                picked = frame
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let picked, device.don != .doffed else {
            Trace.note("no decoded frame (\(trigger.rawValue)): stream \(streamState), decoded \(hevc.decoded), don \(device.don)")
            Log.glasses.info("no stream frame (\(trigger.rawValue, privacy: .public)): stream \(String(describing: self.streamState), privacy: .public), decoded \(self.hevc.decoded), don \(String(describing: self.device.don), privacy: .public)")
            return nil
        }
        let origin = streamOrigin
        return await Task.detached(priority: .userInitiated) { () -> CapturedFrame? in
            guard let (jpeg, size) = HEVCFrameDecoder.jpeg(picked.buffer, quality: 0.9) else { return nil }
            return CapturedFrame(capturedAt: picked.at, origin: origin, jpeg: jpeg, pixelSize: size, isHighRes: false, trigger: trigger)
        }.value
    }

    func requestHighResPhoto() async -> CapturedFrame? {
        if usesPhoto {
            return await takePhoto(resolution: .full, quality: .high, trigger: .highRes)
        }
        // Mode B: photo through the running stream.
        guard let camera, streamState == .streaming, !pendingStreamPhoto.isWaiting else { return nil }
        let started = camera.stream.capturePhoto(format: .jpeg)
        guard started else {
            Log.glasses.info("stream capturePhoto refused; staying on stream frames")
            return nil
        }
        let t0 = ContinuousClock.now
        guard let data = await pendingStreamPhoto.wait(timeout: Self.photoTimeout),
              let jpeg = ImageData.ensureJPEG(data)
        else {
            Log.glasses.error("stream photo did not arrive")
            return nil
        }
        lastTransferMillis = (ContinuousClock.now - t0).milliseconds
        let size = ImageData.pixelSize(of: jpeg)
        Log.glasses.info("stream photo \(Int(size.width))x\(Int(size.height)) in \(self.lastTransferMillis ?? -1) ms")
        return CapturedFrame(origin: photoOrigin, jpeg: jpeg, pixelSize: size, isHighRes: true, trigger: .highRes)
    }

    private func takePhoto(resolution requested: PhotoResolution, quality: PhotoQuality, trigger: CaptureTrigger) async -> CapturedFrame? {
        guard let camera, photoState == .started, !isCapturingStill, device.don != .doffed else { return nil }
        if let readyAt = photoReadyAt {
            let settle = 1.0 - Date().timeIntervalSince(readyAt)
            if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
        }
        let resolution = Self.usableResolution(requested, excluding: failedResolutions)
        isCapturingStill = true
        defer {
            isCapturingStill = false
            transferFraction = nil
        }
        transferFraction = 0
        let t0 = ContinuousClock.now
        // The picture is taken now; the transfer can take 10+ s over Bluetooth. Time and GPS
        // belong to this moment, not to the arrival ("the street we just passed").
        let takenAt = Date()
        camera.photo.capturePhoto(resolution: resolution, quality: quality)
        guard let data = await pendingPhoto.wait(timeout: Self.photoTimeout),
              let raw = ImageData.ensureJPEG(data)
        else {
            // Brief §7: failed photo → carry on silently, log it. A resolution that keeps
            // failing quickly is probably unsupported on this device: step down next time.
            let elapsed = (ContinuousClock.now - t0).milliseconds
            Log.glasses.error("photo (\(resolution.rawValue, privacy: .public)) failed after \(elapsed) ms")
            if elapsed < 3000, resolution != .small {
                let count = (fastFailures[resolution] ?? 0) + 1
                fastFailures[resolution] = count
                if count >= 3 {
                    failedResolutions.insert(resolution)
                    Log.glasses.info("next photo will use \(Self.usableResolution(resolution, excluding: self.failedResolutions).rawValue, privacy: .public)")
                }
            }
            return nil
        }
        fastFailures[resolution] = 0
        lastTransferMillis = (ContinuousClock.now - t0).milliseconds
        // MockDeviceKit hands back the image file as-is (already upright).
        let rotation = MockRuntime.isActive ? 0 : (config?.glassesPhotoRotation ?? 90)
        let jpeg = rotation == 0 ? raw : await Task.detached(priority: .userInitiated) {
            ImageData.rotatedJPEG(raw, clockwiseDegrees: rotation)
        }.value
        let size = ImageData.pixelSize(of: jpeg)
        Log.glasses.info("photo \(Int(size.width))x\(Int(size.height)) \(jpeg.count) B in \(self.lastTransferMillis ?? -1) ms (rotated \(rotation)°)")
        noteThroughput(bytes: raw.count, millis: lastTransferMillis ?? 0)
        return CapturedFrame(capturedAt: takenAt, origin: photoOrigin, jpeg: jpeg, pixelSize: size, isHighRes: true, trigger: trigger)
    }

    private static func usableResolution(_ wanted: PhotoResolution, excluding failed: Set<PhotoResolution>) -> PhotoResolution {
        let ladder: [PhotoResolution] = [.full, .large, .medium, .small]
        let start = ladder.firstIndex(of: wanted) ?? 0
        return ladder[start...].first { !failed.contains($0) } ?? .small
    }

    /// Resolution actually used for stills right now (after fallbacks), for the status line.
    var effectiveStillResolution: String? {
        guard let config, usesPhoto else { return nil }
        return Self.usableResolution(config.stillResolution.sdk, excluding: failedResolutions).rawValue
    }

    // MARK: - Session

    private func startSession() {
        guard session == nil else { return }
        do throws(DeviceSessionError) {
            let newSession = try wearables.createSession(deviceSelector: selector)
            session = newSession
            // Subscribe before start() so the first transition is not missed.
            newSession.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.sessionStateChanged(state) }
            }.store(in: sessionTokens)
            newSession.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.handleSessionError(error) }
            }.store(in: sessionTokens)
            sessionState = .starting
            try newSession.start()
        } catch {
            handleSessionError(error)
            cleanupSession()
        }
        recompute()
    }

    private func sessionStateChanged(_ newState: DeviceSessionState) {
        sessionState = newState
        Log.glasses.info("session → \(newState.description, privacy: .public)")
        switch newState {
        case .started:
            reconnectAttempts = 0
            lastError = nil   // recovered: stale teardown errors no longer apply
            if let session {
                headMotion.attach(to: session)
                buttons.attach(to: session)
                // Microphone permission first: it decides whether the stream carries audio.
                Task { [weak self] in
                    guard let self else { return }
                    await self.prepareSpeech()
                    guard let current = self.session, current.state == .started else { return }
                    self.attachCameraIfNeeded()
                    if self.wantsSpeech() {
                        self.headSpeech.attach(to: current)
                    } else {
                        Log.glasses.info("glasses speech off (setting or microphone permission)")
                    }
                }
            }
        case .stopped:
            // Terminal. A new session is needed to continue (hinge reopen does not revive it).
            cleanupSession()
            // `linkFailed`: we stopped it ourselves to renegotiate the link; always come back.
            if wantRunning, !backgroundPaused, config?.autoReconnect == true || linkFailed, hasActiveDevice {
                scheduleReconnect()
            }
        default:
            break
        }
        recompute()
    }

    private func cleanupSession() {
        liveRecorder.withLock { $0 = nil }
        compressedLive = false
        hevcCheck?.cancel()
        sessionTokens.clear()
        headMotion.detach()
        headSpeech.detach()
        buttons.detach()
        audioWake.stop()
        cameraTokens.clear()
        pendingPhoto.fulfill(nil)
        pendingStreamPhoto.fulfill(nil)
        camera = nil
        session = nil
        sessionState = .stopped
        resetCameraFlags()
    }

    private func resetCameraFlags() {
        streamState = .stopped
        photoState = .stopped
        photoStartRequested = false
        wakeStreamStopIntended = false
        cameraEverStarted = false
        transferFraction = nil
    }

    private func scheduleReconnect() {
        // No attempt limit: a failed Wi-Fi join ("Unable to join the network") used to burn
        // all five attempts within seconds while the SDK was still tearing down, and then
        // nothing ever tried again. Back off instead: 1, 2, 4, 8, 16, 30, 30… s.
        guard reconnectTask == nil else { return }
        reconnectAttempts += 1
        let delay = min(pow(2, Double(reconnectAttempts - 1)), 30)
        if reconnectAttempts >= 2, Self.usesWiFiTransport { Self.forgetGlassesWiFi() }
        Log.glasses.info("reconnect attempt \(self.reconnectAttempts) in \(delay) s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wantRunning, self.session == nil, !self.backgroundPaused,
                  self.hasActiveDevice, self.blocked == nil else { return }
            await self.startSessionIfAllowed()
        }
    }

    // MARK: - Camera

    private func attachCameraIfNeeded() {
        guard let session, session.state == .started, camera == nil, let config else { return }
        let streamConfig: StreamConfiguration
        let background = recordingInBackground
        if background {
            // The SDK keeps .hvc1 streaming in the background (.raw pauses). 720p for legible
            // signs, 2 fps: frames are sampled every ~2.5 s later anyway.
            streamConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .high, frameRate: 2)
        } else if config.mode.usesPhotoCapability {
            // Wake-up stream only: compressed, smallest, slowest. Nothing decodes it.
            streamConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 2)
        } else if config.mode.picksStreamFrames {
            // Only the newest frame is ever used: 2 fps leaves Bluetooth room for 720p
            // (at 7 fps the SDK dropped to 504×896 after a minute, field 14 Nov).
            // With hands-free on, the glasses mic rides along as 16 kHz PCM for wake listening.
            // Over Bluetooth Classic, audio shares a narrow link: ask for 504×896 straight away
            // (the SDK dropped further to 360×640). Over the glasses' Wi-Fi there is room for 720p.
            let audio = streamsAudio
            let roomy = Self.usesWiFiTransport || !audio
            streamConfig = StreamConfiguration(videoCodec: Self.usesWiFiTransport && !hevcFallback ? .hvc1 : .raw,
                                               audioCodec: audio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
                                               resolution: roomy ? .high : .medium,
                                               frameRate: Self.usesWiFiTransport ? 7 : 2)
        } else {
            streamConfig = StreamConfiguration(
                videoCodec: .raw,
                resolution: config.streamQuality.sdk,
                frameRate: config.streamFPS
            )
        }
        do {
            guard let newCamera = try session.addCamera(config: streamConfig) else {
                lastError = String(localized: "Couldn't add the camera. Try again.")
                return
            }
            camera = newCamera
            resetCameraFlags()
            compressedLive = !background && streamConfig.videoCodec == .hvc1 && config.mode.picksStreamFrames
            if compressedLive { hevc.reset() }
            observe(camera: newCamera, photoMode: !background && config.mode.usesPhotoCapability,
                    recorder: background ? backgroundRecorder : nil)
            streamState = .starting
            newCamera.stream.start()
        } catch {
            handleSessionError(error)
        }
        recompute()
    }

    private func observe(camera: MWDATCamera.Camera, photoMode: Bool, recorder: BackgroundSegmentRecorder? = nil) {
        let stream = camera.stream
        camera.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.cameraStateChanged(state) }
        }.store(in: cameraTokens)
        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.streamStateChanged(state) }
        }.store(in: cameraTokens)
        stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handleStreamError(error) }
        }.store(in: cameraTokens)
        stream.photoDataPublisher.listen { [weak self] photo in
            Task { @MainActor in self?.pendingStreamPhoto.fulfill(photo.data) }
        }.store(in: cameraTokens)

        if photoMode {
            let photo = camera.photo
            // Bound once, before any capture: the publisher does not replay history.
            photo.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.photoStateChanged(state) }
            }.store(in: cameraTokens)
            photo.photoDataPublisher.listen { [weak self] data in
                if let meta = data.metadata {
                    let hex = meta.prefix(400).map { String(format: "%02x", $0) }.joined()
                    Log.glasses.debug("photo metadata \(meta.count) B: \(hex, privacy: .public)")
                } else {
                    Log.glasses.debug("photo metadata: none")
                }
                Task { @MainActor in self?.pendingPhoto.fulfill(data.imageData) }
            }.store(in: cameraTokens)
            photo.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.handlePhotoError(error) }
            }.store(in: cameraTokens)
            photo.transferProgressPublisher.listen { [weak self] progress in
                Task { @MainActor in self?.transferFraction = progress.fraction }
            }.store(in: cameraTokens)
        } else if config?.mode.picksStreamFrames == true, recorder == nil {
            // Adaptive: keep only the newest frame; the scheduler takes it when a still is due.
            let latest = latestFrame
            latest.withLock { $0 = nil }
            if compressedLive {
                let decoder = hevc
                let recorderBox = liveRecorder
                stream.videoFramePublisher.listen { frame in
                    let sample = frame.sampleBuffer
                    // Background: straight to the file (no hardware decoder for a background
                    // app); foreground: decode, keep the newest picture.
                    // Background: also into a file, in case iOS gives no decoder there; the
                    // file is dropped if frames were understood live (`backgroundKept`).
                    recorderBox.withLock({ $0 })?.append(sample)
                    decoder.decode(sample)
                }.store(in: cameraTokens)
            } else {
                stream.videoFramePublisher.listen { frame in
                    latest.withLock { $0 = (frame, Date()) }
                }.store(in: cameraTokens)
            }
            if streamsAudio {
                let wake = audioWake
                let speech = headSpeech
                let tap = micTap
                let wakeListening = wantsSpeech()
                stream.audioFramePublisher.listen { frame in
                    let buffer = frame.pcmBuffer
                    if wakeListening { wake.append(buffer) }
                    tap.feed(buffer)
                }.store(in: cameraTokens)
                if wakeListening {
                    wake.start(contextualStrings: wakeStrings(), onPartial: { text in
                        Task { @MainActor in speech.partial(text) }
                    }) { text in
                        Task { @MainActor in speech.utterance(text, source: "phone") }
                    }
                }
                Log.glasses.info("camera stream carries the glasses mic (push-to-talk\(wakeListening ? " + wake word" : "", privacy: .public))")
            }
        } else if let recorder {
            // Background: compressed samples go straight to the file, nothing is decoded.
            stream.videoFramePublisher.listen { frame in
                recorder.append(frame.sampleBuffer)
            }.store(in: cameraTokens)
        } else {
            // Frames never touch the main actor: encode on a background queue, drop when busy.
            let encoder = encoder
            encoder.setFrameRate(config?.streamFPS ?? 7)
            let continuation = frameContinuation
            let origin = streamOrigin
            stream.videoFramePublisher.listen { frame in
                encoder.encode(frame, origin: origin, into: continuation)
            }.store(in: cameraTokens)
        }
    }

    private func cameraStateChanged(_ cameraState: CameraState) {
        switch cameraState {
        case .started:
            cameraEverStarted = true
            reattachAttempts = 0
        case .stopped:
            // Born `.stopped` too, so only a camera that was up and went down counts.
            guard cameraEverStarted, camera != nil else { break }
            Log.glasses.info("camera went down")
            audioWake.stop()
            cameraTokens.clear()
            camera = nil
            pendingPhoto.fulfill(nil)
            pendingStreamPhoto.fulfill(nil)
            resetCameraFlags()
            scheduleReattach()
        default:
            break
        }
        recompute()
    }

    /// Stops streaming the glasses mic and rebuilds the camera without it. Wake listening goes
    /// on through the glasses' own transcription (text only).
    private func dropAudio(reason: String) {
        guard !audioDisabled else { return }
        audioDisabled = true
        audioStreamErrors = []
        audioWake.stop()
        Log.glasses.info("glasses audio off (\(reason, privacy: .public)): video only, wake word via glasses transcription")
        // The camera going down reattaches it with the new (video-only) configuration.
        reattachAttempts = 0
        camera?.stop()
    }

    private func scheduleReattach() {
        guard wantRunning else { return }
        reattachAttempts += 1
        if reattachAttempts > 2, let session {
            // The camera keeps failing on this session (often the Wi-Fi link): start over with
            // a new session, which negotiates the link again; `.stopped` schedules it.
            Log.glasses.info("camera failed \(self.reattachAttempts - 1) times: new session")
            linkFailed = true
            reattachAttempts = 0
            session.stop()
            return
        }
        let delay = Double(reattachAttempts)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.wantRunning, self.camera == nil,
                  self.session?.state == .started else { return }
            self.attachCameraIfNeeded()
        }
    }

    private func streamStateChanged(_ newState: StreamState) {
        streamState = newState
        Log.glasses.info("stream → \(String(describing: newState), privacy: .public)")
        armStreamWatchdog(for: newState)
        switch newState {
        case .streaming:
            linkFailed = false
            reattachAttempts = 0
            if compressedLive { checkDecoding() }
            if usesPhoto, !recordingInBackground { startPhotoIfNeeded() }
        case .stopped:
            if usesPhoto, wakeStreamStopIntended {
                break   // ours: the photo capability now has the sensor to itself
            }
            pendingStreamPhoto.fulfill(nil)
            if camera != nil {
                // Stream ended on its own while the session may still be up. Teardown cascades
                // parent → child only, so detach the camera explicitly and try again.
                camera?.stop()
                cameraTokens.clear()
                camera = nil
                resetCameraFlags()
                scheduleReattach()
            }
        default:
            break
        }
        recompute()
    }

    /// Safety net: if the `.hvc1` stream gives no decodable picture within 8 s, use `.raw`.
    private func checkDecoding() {
        hevcCheck?.cancel()
        let current = camera
        hevcCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.compressedLive, self.camera === current,
                  self.streamState == .streaming, !self.recordingInBackground else { return }
            if self.hevc.decoded > 0 {
                Log.glasses.info("HEVC stream decoding: \(self.hevc.decoded) frames in 8 s")
                return
            }
            Log.glasses.info("HEVC stream gave no picture in 8 s: switching to raw frames")
            self.hevcFallback = true
            self.detachCamera()
            self.attachCameraIfNeeded()
        }
    }

    /// A stream stuck in "starting" (the Wi-Fi join timed out inside the SDK and nothing told
    /// us) counts as a failure after 25 s: the camera is rebuilt, then the session.
    private func armStreamWatchdog(for newState: StreamState) {
        streamWatchdog?.cancel()
        streamWatchdog = nil
        guard newState == .starting || newState == .waitingForDevice else { return }
        streamWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled, self.wantRunning, !self.recordingInBackground,
                  self.streamState == newState, self.camera != nil,
                  self.device.link == .connected, self.device.hinge != .closed, self.device.don != .doffed else { return }
            Log.glasses.info("stream stuck in \(String(describing: newState), privacy: .public) for 25 s: retrying")
            self.linkFailed = true
            self.camera?.stop()
            self.cameraTokens.clear()
            self.camera = nil
            self.resetCameraFlags()
            self.scheduleReattach()
        }
    }

    /// Wi-Fi networks this app configured (the glasses' hotspot; iOS lists only our own).
    /// After a failed join iOS can keep the stale entry; removing it makes the next attempt
    /// join afresh.
    static func forgetGlassesWiFi() {
        NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
            guard !ssids.isEmpty else { return }
            Log.glasses.info("forgetting \(ssids.count) glasses Wi-Fi configuration(s) for a fresh join")
            ssids.forEach { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: $0) }
        }
    }

    private func startPhotoIfNeeded() {
        guard !photoStartRequested, let camera else { return }
        photoStartRequested = true
        camera.photo.start()
    }

    private func photoStateChanged(_ newState: PhotoState) {
        photoState = newState
        Log.glasses.info("photo → \(String(describing: newState), privacy: .public)")
        switch newState {
        case .started:
            photoReadyAt = Date()
            if !wakeStreamStopIntended {
                wakeStreamStopIntended = true
                camera?.stream.stop()   // stills and frames compete for the sensor
            }
        case .stopped:
            pendingPhoto.fulfill(nil)
            if photoStartRequested, wantRunning, let camera, session?.state == .started {
                // Photo capability fell over with the camera still attached: wake it again.
                photoStartRequested = false
                wakeStreamStopIntended = false
                camera.stream.start()
            }
        default:
            break
        }
        recompute()
    }

    // MARK: - Errors

    private var errorsSuppressed: Bool {
        if let until = suppressErrorsUntil, Date() < until { return true }
        return false
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        Log.glasses.error("session error: \(String(describing: error), privacy: .public)")
        guard !errorsSuppressed else { return }
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            needsGlassesAppUpdate = true
            lastError = String(localized: "The app on your glasses needs an update.")
        case .noEligibleDevice:
            lastError = String(localized: "No compatible glasses found. Are they on, unfolded and nearby?")
        case .thermalCritical, .thermalEmergency:
            lastError = String(localized: "\(error.localizedDescription) Wait for the glasses to cool down.")
        case .batteryCritical, .peakPowerShutdown:
            lastError = String(localized: "\(error.localizedDescription) Charge your glasses.")
        case .insufficientSDKVersion:
            blocked = .failed(message: error.localizedDescription)
        case .dwaOutOfStuRange:
            break   // non-blocking compatibility warning
        case .unexpectedError(let description):
            // Session teardown (folded, taken off, out of range) arrives here as free text.
            // No raw SDK text on screen and no matching on it: the device state ("Waiting for
            // glasses") and auto-reconnect already tell the user what is happening.
            Log.glasses.info("session error: \(description, privacy: .public)")
            lastError = nil
        default:
            lastError = error.localizedDescription
        }
        recompute()
    }

    private func handleStreamError(_ error: StreamError) {
        Log.glasses.error("stream error: \(String(describing: error), privacy: .public)")
        guard !errorsSuppressed else { return }
        switch error {
        case .permissionDenied:
            permissionVerified = false
            blocked = .needsPermission
            lastError = String(localized: "No camera access. Allow it or switch to the iPhone camera.")
        case .hingesClosed:
            lastError = String(localized: "Glasses were folded or taken off. Unfold them to start a new session.")
        case .thermalHot, .batteryLow, .peakPowerLimit:
            lastError = String(localized: "\(error.localizedDescription) Adaptive mode saves battery and reduces heat.")
        case .photoCaptureFailed:
            pendingStreamPhoto.fulfill(nil)   // silent: keep using stream frames
        case .audioStreamingError:
            // Wake listening falls back to the glasses' own transcription; video goes on.
            dropAudio(reason: "audio streaming error")
            return
        case .videoStreamingError where streamsAudio:
            // Video hiccups after audio joined the link (field 14 Nov: none in 4 min without
            // audio, two in a minute with it). Twice in 3 minutes: video only from now on.
            let now = Date()
            audioStreamErrors = audioStreamErrors.filter { now.timeIntervalSince($0) < 180 } + [now]
            if audioStreamErrors.count >= 2 { dropAudio(reason: "video errors with audio on") }
            return
        default:
            lastError = error.localizedDescription
        }
        recompute()
    }

    private func handlePhotoError(_ error: PhotoError) {
        Log.glasses.error("photo error: \(error.description, privacy: .public) · \(String(describing: error), privacy: .public)")
        pendingPhoto.fulfill(nil)
        guard !errorsSuppressed else { return }
        switch error {
        case .permissionDenied:
            permissionVerified = false
            blocked = .needsPermission
            lastError = String(localized: "No camera access.")
        case .deviceHealthCritical:
            lastError = String(localized: "\(error.localizedDescription) Give the glasses a rest.")
        default:
            break   // capture failures are logged, not shown
        }
        recompute()
    }

    // MARK: - Device

    private func startDeviceMonitoring() {
        deviceMonitorTask = Task { [weak self] in
            guard let sequence = self?.selector.activeDeviceStream() else { return }
            for await deviceId in sequence {
                guard let self else { return }
                self.activeDeviceChanged(deviceId)
            }
        }
    }

    private func activeDeviceChanged(_ deviceId: DeviceIdentifier?) {
        Log.glasses.info("active device → \(deviceId ?? "none", privacy: .public)")
        let appeared = deviceId != nil && !hasActiveDevice
        hasActiveDevice = deviceId != nil
        observeDeviceState(deviceId)
        if appeared {
            reconnectAttempts = 0
            if wantRunning, session == nil, !backgroundPaused, blocked == nil,
               config?.autoReconnect == true || state == .waitingForDevice {
                scheduleReconnect()
            }
        }
        recompute()
    }

    private func observeDeviceState(_ deviceId: DeviceIdentifier?) {
        guard deviceId != observedDeviceId else { return }
        observedDeviceId = deviceId
        if let old = deviceStateToken {
            Task { await old.cancel() }
            deviceStateToken = nil
        }
        guard let deviceId, let device = wearables.deviceForIdentifier(deviceId) else {
            self.device = GlassesDeviceStatus()
            return
        }
        let name = device.nameOrId()
        deviceStateToken = device.addDeviceStateListener { [weak self] deviceState in
            Task { @MainActor in self?.apply(deviceState, name: name) }
        }
    }

    private func apply(_ deviceState: DeviceState, name: String) {
        Log.glasses.info("device \(name, privacy: .public): link \(String(describing: deviceState.linkState), privacy: .public) hinge \(String(describing: deviceState.hingeState), privacy: .public) don \(String(describing: deviceState.donState), privacy: .public) battery \(deviceState.batteryLevel ?? -1)")
        let previous = device
        device = GlassesDeviceStatus(
            name: name,
            link: deviceState.linkState,
            battery: deviceState.batteryLevel,
            charging: deviceState.chargingState,
            don: deviceState.donState,
            hinge: deviceState.hingeState,
            thermal: deviceState.thermalLevel
        )
        // Device came back into a usable shape (connected, worn, hinge open) while we are
        // waiting for it: give the reconnect loop a fresh budget.
        let improved = (previous.link != .connected && device.link == .connected)
            || (previous.don != .donned && device.don == .donned)
            || (previous.hinge != .open && device.hinge == .open)
        if improved, wantRunning, session == nil, hasActiveDevice, !backgroundPaused, blocked == nil,
           config?.autoReconnect == true {
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            scheduleReconnect()
        }
        recompute()
    }

    // MARK: - App lifecycle

    private func startBackgroundMonitoring() {
        backgroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.handleDidEnterBackground()
            }
        }
        foregroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                await self?.handleWillEnterForeground()
            }
        }
    }

    /// Background capture (default): swap the camera to an `.hvc1` stream, which the SDK keeps
    /// running in the background, and write it to a file. Without it (setting off, or no
    /// running session): end the session on purpose and offer "Resume" on return.
    private func handleDidEnterBackground() {
        Trace.inBackground = true
        Trace.note("enter background (running \(wantRunning), compressed \(compressedLive), decoded \(hevc.decoded))")
        guard wantRunning, session != nil else { return }
        if config?.backgroundCapture == true, session?.state == .started, compressedLive, camera != nil {
            // Same stream, now into a file: the camera and its Wi-Fi link stay as they are.
            recordingInBackground = true
            let recorder = BackgroundSegmentRecorder(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("background", isDirectory: true))
            backgroundRecorder = recorder
            backgroundKept = 0
            liveRecorder.withLock { $0 = recorder }
            Log.glasses.info("background: live HEVC frames + backup file (camera kept)")
            recompute()
            return
        }
        if config?.backgroundCapture == true, session?.state == .started {
            recordingInBackground = true
            backgroundRecorder = BackgroundSegmentRecorder(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("background", isDirectory: true))
            detachCamera()
            Log.glasses.info("background: recording the HEVC stream")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.attachCameraIfNeeded()
            }
            recompute()
            return
        }
        backgroundPaused = true
        suppressErrorsUntil = Date().addingTimeInterval(5)
        reconnectTask?.cancel()
        reconnectTask = nil
        camera?.stop()
        session?.stop()
        recompute()
    }

    /// Back in the foreground: close the background file, hand it over, restore the camera.
    private func handleWillEnterForeground() async {
        Trace.inBackground = false
        Trace.note("enter foreground (decoded \(hevc.decoded), kept while locked \(backgroundKept))")
        guard recordingInBackground else { return }
        recordingInBackground = false
        if compressedLive, camera != nil {
            liveRecorder.withLock { $0 = nil }
            // Decoder still delivering: keep it; otherwise restart at the next key frame.
            if hevc.newest(maxAge: 2, take: false) == nil { hevc.reset() }
            recompute()
            let live = backgroundKept >= 3
            Log.glasses.info("foreground: \(self.backgroundKept) memories kept live while locked; backup file \(live ? "dropped" : "processed", privacy: .public)")
            await finishBackgroundRecording(discard: live)
            return
        }
        detachCamera()
        recompute()
        await finishBackgroundRecording()
        try? await Task.sleep(for: .milliseconds(500))
        if wantRunning { attachCameraIfNeeded() }
    }

    private func finishBackgroundRecording(discard: Bool = false) async {
        let recorder = backgroundRecorder
        backgroundRecorder = nil
        if let segment = await recorder?.finish() {
            if discard {
                try? FileManager.default.removeItem(at: segment.url)
                return
            }
            Log.glasses.info("background segment: \(Int(segment.duration)) s")
            segmentContinuation.yield(segment)
        }
    }

    private func detachCamera() {
        liveRecorder.withLock { $0 = nil }
        compressedLive = false
        hevcCheck?.cancel()
        camera?.stop()
        cameraTokens.clear()
        camera = nil
        resetCameraFlags()
        pendingPhoto.fulfill(nil)
        pendingStreamPhoto.fulfill(nil)
    }

    // MARK: - Derived state

    private func recompute() {
        let next: CaptureState
        if let blocked {
            next = blocked
        } else if !wantRunning {
            next = .idle
        } else if backgroundPaused {
            next = .paused(reason: String(localized: "returned from background", comment: "Reason shown after 'Paused:'"))
        } else if session == nil {
            next = .waitingForDevice
        } else {
            switch sessionState {
            case .idle, .starting:
                next = .starting
            case .stopping, .stopped:
                next = .waitingForDevice
            case .paused:
                // A cap-touch tap pauses both stream and session; say "tap to resume" then.
                if streamState == .paused || photoState == .started {
                    next = .paused(reason: device.don == .doffed ? Self.doffedReason : Self.tapReason)
                } else {
                    next = .paused(reason: String(localized: "glasses switched to another experience", comment: "Reason shown after 'Paused:'"))
                }
            case .started:
                next = startedState()
            @unknown default:
                next = .starting
            }
        }
        state = next
    }

    private static let doffedReason = String(localized: "glasses aren't on; put them on and tap the temple", comment: "Reason shown after 'Paused:'")
    private static let tapReason = String(localized: "tap the glasses' temple to resume", comment: "Reason shown after 'Paused:'")

    private func startedState() -> CaptureState {
        let doffedReason = Self.doffedReason
        let tapReason = Self.tapReason
        if usesPhoto {
            if photoState == .started {
                return device.don == .doffed ? .paused(reason: doffedReason) : .running
            }
            switch streamState {
            case .paused: return .paused(reason: device.don == .doffed ? doffedReason : tapReason)
            case .waitingForDevice: return .waitingForDevice
            default: return .starting
            }
        }
        switch streamState {
        case .streaming: return .running
        case .paused: return .paused(reason: device.don == .doffed ? doffedReason : tapReason)
        case .waitingForDevice: return .waitingForDevice
        default: return .starting
        }
    }
}

// MARK: - Helpers

/// One awaited value with a timeout. Resumes exactly once. Each wait has its own id so a
/// timeout left over from an earlier wait can never cut a later one short.
@MainActor
final class OneShot<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var waitId = 0
    private var timeoutTask: Task<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait(timeout: Duration) async -> Value? {
        fulfill(nil)   // never strand an earlier waiter
        waitId += 1
        let id = waitId
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, self.waitId == id else { return }
                self.fulfill(nil)
            }
        }
    }

    func fulfill(_ value: Value?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// JPEG-encodes `.raw` stream frames on a background queue. Frames arriving faster than the
/// requested rate (MockDeviceKit plays files at their native rate) or while the previous one
/// is still encoding are dropped: memory stays flat and the main thread never blocks.
final class StreamFrameEncoder: Sendable {
    private struct Gate {
        var busy = false
        var lastAccepted: ContinuousClock.Instant?
        var minSpacing: Duration = .zero
    }

    private let queue = DispatchQueue(label: "fi.junction.muisti.encode", qos: .userInitiated)
    private let gate = OSAllocatedUnfairLock(initialState: Gate())

    func setFrameRate(_ fps: UInt) {
        // 10 % slack so a device delivering exactly at `fps` is never throttled.
        let spacing = Duration.milliseconds(Int(900.0 / Double(max(fps, 1))))
        gate.withLock { $0.minSpacing = spacing; $0.lastAccepted = nil }
    }

    func encode(_ frame: VideoFrame, origin: CaptureOrigin, into continuation: AsyncStream<CapturedFrame>.Continuation) {
        let now = ContinuousClock.now
        let acquired = gate.withLock { g -> Bool in
            if g.busy { return false }
            if let last = g.lastAccepted, now - last < g.minSpacing { return false }
            g.busy = true
            g.lastAccepted = now
            return true
        }
        guard acquired else { return }
        let gate = gate
        queue.async {
            defer { gate.withLock { $0.busy = false } }
            guard let image = frame.makeUIImage(),
                  let jpeg = image.jpegData(compressionQuality: 0.8)
            else { return }
            let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            continuation.yield(
                CapturedFrame(origin: origin, jpeg: jpeg, pixelSize: size, isHighRes: false, trigger: .stream)
            )
        }
    }
}

extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

extension StreamQuality {
    var sdk: StreamingResolution {
        switch self {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }
}

extension StillResolution {
    var sdk: PhotoResolution {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .full: return .full
        }
    }
}

extension StillQuality {
    var sdk: PhotoQuality {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
