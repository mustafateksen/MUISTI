import CoreGraphics
import Foundation
import MWDATCamera
import MWDATCore
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
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var config: CaptureConfig?

    @ObservationIgnored private var wantRunning = false
    /// Blocks everything until the user acts: registration, permission, fatal error.
    @ObservationIgnored private var blocked: CaptureState?
    @ObservationIgnored private var backgroundPaused = false
    @ObservationIgnored private var suppressErrorsUntil: Date?

    @ObservationIgnored private var wakeStreamStopIntended = false
    @ObservationIgnored private var photoStartRequested = false
    @ObservationIgnored private var cameraEverStarted = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reattachAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    @ObservationIgnored private let sessionTokens = ListenerTokenBag()
    @ObservationIgnored private let cameraTokens = ListenerTokenBag()
    @ObservationIgnored private var deviceStateToken: (any AnyListenerToken)?
    @ObservationIgnored private var observedDeviceId: DeviceIdentifier?

    @ObservationIgnored private let pendingPhoto = OneShot<Data>()
    @ObservationIgnored private let pendingStreamPhoto = OneShot<Data>()
    @ObservationIgnored private let encoder = StreamFrameEncoder()

    @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

    private static let photoTimeout: Duration = .seconds(10)

    init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        selector = AutoDeviceSelector(wearables: wearables)
        (frames, frameContinuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(2))
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
            return "Gözlük açık, menteşesi açık ve telefonun yakınında olmalı."
        }
        if device.hinge == .closed { return "Menteşe kapalı. Açınca yeni oturum kurulur." }
        if device.don == .doffed { return "Gözlük takılı değil. Takınca yeniden bağlanır." }
        if device.link != .connected { return "Gözlük bağlanıyor…" }
        if config?.autoReconnect == true, reconnectAttempts >= 5 {
            return "Bağlanılamadı. Durdurup yeniden başlat."
        }
        return "Gözlüğe yeniden bağlanılıyor…"
    }

    /// Battery / heat warning derived from device state (brief §7). The SDK also reports
    /// `StreamError.batteryLow/.thermalHot`, but those arrive only once the device acts.
    var healthWarning: String? {
        guard hasActiveDevice else { return nil }
        let suggestion = usesPhoto ? "" : " Uyarlamalı moda geçmek pili ve ısıyı rahatlatır."
        switch device.thermal {
        case .critical, .emergency, .shutdown:
            return "Gözlük aşırı ısındı; çekim duraklatıldı, soğumasını bekle."
        case .severe:
            return "Gözlük ısınıyor; çekim seyreltildi." + suggestion
        default:
            break
        }
        if let battery = device.battery, battery < 15, device.charging != .charging {
            return "Gözlük pili düşük (%\(battery)); çekim seyreltildi." + suggestion
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

        guard wearables.registrationState == .registered else {
            blocked = .needsRegistration
            recompute()
            return
        }

        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                blocked = .needsPermission
                recompute()
                return
            }
        } catch {
            // No connected device to ask yet. Not a denial: wait for the device, and let the
            // stream report `.permissionDenied` if it really is missing.
            Log.glasses.info("permission check deferred: \(error.description, privacy: .public)")
        }

        if session == nil, hasActiveDevice {
            startSession()
        }
        recompute()
    }

    /// Call after the user confirmed the switch to Meta AI.
    func requestPermissionAndStart(using controller: WearablesController) async {
        guard let config else { return }
        if await controller.requestCameraPermission() {
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
        backgroundPaused = false
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
        guard usesPhoto else { return nil }   // stream modes deliver through `frames`
        guard let config else { return nil }
        return await takePhoto(
            resolution: config.stillResolution.sdk,
            quality: config.stillQuality.sdk,
            trigger: trigger
        )
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

    private func takePhoto(resolution: PhotoResolution, quality: PhotoQuality, trigger: CaptureTrigger) async -> CapturedFrame? {
        guard let camera, photoState == .started, !isCapturingStill, device.don != .doffed else { return nil }
        isCapturingStill = true
        defer {
            isCapturingStill = false
            transferFraction = nil
        }
        transferFraction = 0
        let t0 = ContinuousClock.now
        camera.photo.capturePhoto(resolution: resolution, quality: quality)
        guard let data = await pendingPhoto.wait(timeout: Self.photoTimeout),
              let jpeg = ImageData.ensureJPEG(data)
        else {
            // Brief §7: failed photo → carry on silently, log it.
            Log.glasses.error("photo (\(resolution.rawValue, privacy: .public)) did not arrive within timeout")
            return nil
        }
        lastTransferMillis = (ContinuousClock.now - t0).milliseconds
        let size = ImageData.pixelSize(of: jpeg)
        Log.glasses.info("photo \(Int(size.width))x\(Int(size.height)) \(jpeg.count) B in \(self.lastTransferMillis ?? -1) ms")
        return CapturedFrame(origin: photoOrigin, jpeg: jpeg, pixelSize: size, isHighRes: true, trigger: trigger)
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
            attachCameraIfNeeded()
        case .stopped:
            // Terminal. A new session is needed to continue (hinge reopen does not revive it).
            cleanupSession()
            if wantRunning, !backgroundPaused, config?.autoReconnect == true, hasActiveDevice {
                scheduleReconnect()
            }
        default:
            break
        }
        recompute()
    }

    private func cleanupSession() {
        sessionTokens.clear()
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
        guard reconnectTask == nil, reconnectAttempts < 5 else { return }
        reconnectAttempts += 1
        let delay = Double(reconnectAttempts)
        Log.glasses.info("reconnect attempt \(self.reconnectAttempts) in \(delay) s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wantRunning, self.session == nil, !self.backgroundPaused,
                  self.hasActiveDevice, self.blocked == nil else { return }
            self.startSession()
        }
    }

    // MARK: - Camera

    private func attachCameraIfNeeded() {
        guard let session, session.state == .started, camera == nil, let config else { return }
        let streamConfig: StreamConfiguration
        if config.mode.usesPhotoCapability {
            // Wake-up stream only: compressed, smallest, slowest. Nothing decodes it.
            streamConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 2)
        } else {
            streamConfig = StreamConfiguration(
                videoCodec: .raw,
                resolution: config.streamQuality.sdk,
                frameRate: config.streamFPS
            )
        }
        do {
            guard let newCamera = try session.addCamera(config: streamConfig) else {
                lastError = "Kamera eklenemedi. Tekrar dene."
                return
            }
            camera = newCamera
            resetCameraFlags()
            observe(camera: newCamera, photoMode: config.mode.usesPhotoCapability)
            streamState = .starting
            newCamera.stream.start()
        } catch {
            handleSessionError(error)
        }
        recompute()
    }

    private func observe(camera: MWDATCamera.Camera, photoMode: Bool) {
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
                Task { @MainActor in self?.pendingPhoto.fulfill(data.imageData) }
            }.store(in: cameraTokens)
            photo.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.handlePhotoError(error) }
            }.store(in: cameraTokens)
            photo.transferProgressPublisher.listen { [weak self] progress in
                Task { @MainActor in self?.transferFraction = progress.fraction }
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

    private func scheduleReattach() {
        guard wantRunning, reattachAttempts < 3 else { return }
        reattachAttempts += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.wantRunning, self.camera == nil,
                  self.session?.state == .started else { return }
            self.attachCameraIfNeeded()
        }
    }

    private func streamStateChanged(_ newState: StreamState) {
        streamState = newState
        Log.glasses.debug("stream → \(String(describing: newState), privacy: .public)")
        switch newState {
        case .streaming:
            if usesPhoto { startPhotoIfNeeded() }
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

    private func startPhotoIfNeeded() {
        guard !photoStartRequested, let camera else { return }
        photoStartRequested = true
        camera.photo.start()
    }

    private func photoStateChanged(_ newState: PhotoState) {
        photoState = newState
        Log.glasses.debug("photo → \(String(describing: newState), privacy: .public)")
        switch newState {
        case .started:
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
        Log.glasses.error("session error: \(error.description, privacy: .public)")
        guard !errorsSuppressed else { return }
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            needsGlassesAppUpdate = true
            lastError = "Gözlükteki uygulamanın güncellenmesi gerekiyor."
        case .noEligibleDevice:
            lastError = "Uygun gözlük yok. Gözlük açık, menteşesi açık ve yakında mı?"
        case .thermalCritical, .thermalEmergency:
            lastError = "\(error.localizedDescription) Gözlük soğuyana kadar bekle."
        case .batteryCritical, .peakPowerShutdown:
            lastError = "\(error.localizedDescription) Gözlüğü şarj et."
        case .insufficientSDKVersion:
            blocked = .failed(message: error.localizedDescription)
        case .dwaOutOfStuRange:
            break   // non-blocking compatibility warning
        default:
            lastError = error.localizedDescription
        }
        recompute()
    }

    private func handleStreamError(_ error: StreamError) {
        Log.glasses.error("stream error: \(error.description, privacy: .public)")
        guard !errorsSuppressed else { return }
        switch error {
        case .permissionDenied:
            blocked = .needsPermission
            lastError = "Kamera izni yok. İzin ver ya da telefon kamerasına geç."
        case .hingesClosed:
            lastError = "Menteşe kapandı ya da gözlük çıkarıldı. Açınca yeni oturum gerekir."
        case .thermalHot, .batteryLow, .peakPowerLimit:
            lastError = "\(error.localizedDescription) Uyarlamalı mod pil ve ısıyı rahatlatır."
        case .photoCaptureFailed:
            pendingStreamPhoto.fulfill(nil)   // silent: keep using stream frames
        default:
            lastError = error.localizedDescription
        }
        recompute()
    }

    private func handlePhotoError(_ error: PhotoError) {
        Log.glasses.error("photo error: \(error.description, privacy: .public)")
        pendingPhoto.fulfill(nil)
        guard !errorsSuppressed else { return }
        switch error {
        case .permissionDenied:
            blocked = .needsPermission
            lastError = "Kamera izni yok."
        case .deviceHealthCritical:
            lastError = "\(error.localizedDescription) Gözlük dinlensin."
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
        Log.glasses.debug("device \(name, privacy: .public): link \(String(describing: deviceState.linkState), privacy: .public) hinge \(String(describing: deviceState.hingeState), privacy: .public) don \(String(describing: deviceState.donState), privacy: .public) battery \(deviceState.batteryLevel ?? -1)")
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
    }

    /// Mirrors the sample: end the session on purpose, hide the expected teardown errors
    /// for 5 s, and offer "Devam et" on return. Background streaming is not relied upon.
    private func handleDidEnterBackground() {
        guard wantRunning, session != nil else { return }
        backgroundPaused = true
        suppressErrorsUntil = Date().addingTimeInterval(5)
        reconnectTask?.cancel()
        reconnectTask = nil
        camera?.stop()
        session?.stop()
        recompute()
    }

    // MARK: - Derived state

    private func recompute() {
        let next: CaptureState
        if let blocked {
            next = blocked
        } else if !wantRunning {
            next = .idle
        } else if backgroundPaused {
            next = .paused(reason: "arka plandan dönüldü")
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
                    next = .paused(reason: "gözlük başka bir deneyime geçti")
                }
            case .started:
                next = startedState()
            @unknown default:
                next = .starting
            }
        }
        state = next
    }

    private static let doffedReason = "gözlük takılı değil; takınca sapa dokun"
    private static let tapReason = "devam için gözlüğün sapına dokun"

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

/// One awaited value with a timeout. Resumes exactly once.
@MainActor
final class OneShot<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait(timeout: Duration) async -> Value? {
        fulfill(nil)   // never strand an earlier waiter
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fulfill(nil)
            }
        }
    }

    func fulfill(_ value: Value?) {
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
