#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import MWDATCore
import MWDATMockDevice
import Observation

/// MockDeviceKit in one place. Once enabled, `GlassesCaptureSource` talks to the simulated
/// glasses through exactly the same SDK calls as real ones.
@Observable
@MainActor
final class MockDeviceController {
    enum Feed: Equatable {
        case bundledDemo
        case file(URL)
        case phoneCamera
    }

    private(set) var isEnabled = false
    private(set) var isPaired = false
    private(set) var isPoweredOn = false
    private(set) var isUnfolded = false
    private(set) var isDonned = false
    private(set) var feed: Feed = .bundledDemo
    private(set) var batteryLevel = 80
    private(set) var thermal: ThermalLevel = .none
    private(set) var isImporting = false
    var lastError: String?

    @ObservationIgnored private var glasses: (any MockGlasses)?
    @ObservationIgnored private let kit = MockDeviceKit.shared

    static var bundledVideoURL: URL? { Bundle.main.url(forResource: "demo_signs", withExtension: "mp4") }
    static var bundledPhotoURL: URL? { Bundle.main.url(forResource: "demo_sign", withExtension: "jpg") }

    var feedLabel: String {
        switch feed {
        case .bundledDemo: return "Bundled sign video"
        case .file(let url): return url.lastPathComponent
        case .phoneCamera: return "iPhone rear camera"
        }
    }

    // MARK: Enable / pair

    /// One tap: registered + permitted kit, Ray-Ban Meta paired, powered, unfolded, worn,
    /// fed with the current feed. `registered: false` exercises the registration/permission UI.
    func quickStart(registered: Bool = true, permissionsGranted: Bool = true) {
        enable(registered: registered, permissionsGranted: permissionsGranted)
        pair()
    }

    func enable(registered: Bool = true, permissionsGranted: Bool = true) {
        guard !isEnabled else { return }
        kit.enable(config: MockDeviceKitConfig(
            initiallyRegistered: registered,
            initialPermissionsGranted: permissionsGranted
        ))
        isEnabled = true
        MockRuntime.isActive = true
        Log.mock.info("MockDeviceKit enabled (registered: \(registered), permitted: \(permissionsGranted))")
    }

    func pair() {
        guard isEnabled, glasses == nil else { return }
        do {
            let g = try kit.pairGlasses(model: .rayBanMeta)
            glasses = g
            isPaired = true
            // Without power + open hinge the device never shows up in devicesStream().
            g.powerOn(); isPoweredOn = true
            g.unfold(); isUnfolded = true
            g.don(); isDonned = true
            g.setBatteryLevel(batteryLevel)
            applyFeed()
            applyPhoto()
        } catch {
            lastError = error.description
        }
    }

    func disable() async {
        await kit.disable()
        glasses = nil
        isEnabled = false
        isPaired = false
        isPoweredOn = false
        isUnfolded = false
        isDonned = false
        MockRuntime.isActive = false
    }

    // MARK: Feeds

    func useBundledDemo() {
        feed = .bundledDemo
        applyFeed()
    }

    func usePhoneCamera() {
        feed = .phoneCamera
        applyFeed()
    }

    /// Copies (and if needed converts to HEVC) a picked/recorded video, then feeds it.
    func importVideo(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let stored = try await MockVideoImporter.importAsHEVC(url)
            feed = .file(stored)
            applyFeed()
        } catch {
            lastError = "Couldn't import video: \(error.localizedDescription)"
        }
    }

    private func applyFeed() {
        guard let camera = glasses?.services.camera else { return }
        switch feed {
        case .bundledDemo:
            if let url = Self.bundledVideoURL { camera.setCameraFeed(fileURL: url) }
        case .file(let url):
            camera.setCameraFeed(fileURL: url)
        case .phoneCamera:
            camera.setCameraFeed(cameraFacing: .back)
        }
    }

    /// Same picture whichever photo path the app asks (stream photo or photo capability).
    private func applyPhoto() {
        guard let services = glasses?.services, let url = Self.bundledPhotoURL else { return }
        services.camera.setCapturedImage(fileURL: url)
        services.cameraCapture.setCapturedPhoto(fileURL: url)
    }

    // MARK: Device states (brief §7 rows)

    func setPower(_ on: Bool) {
        guard let glasses else { return }
        if on { glasses.powerOn() } else { glasses.powerOff() }
        isPoweredOn = on
    }

    func setUnfolded(_ open: Bool) {
        guard let glasses else { return }
        if open { glasses.unfold() } else { glasses.fold() }
        isUnfolded = open
    }

    func setDonned(_ worn: Bool) {
        guard let glasses else { return }
        if worn { glasses.don() } else { glasses.doff() }
        isDonned = worn
    }

    func tap() { glasses?.services.captouch.tap() }

    func setBattery(_ level: Int) {
        batteryLevel = level
        glasses?.setBatteryLevel(level)
    }

    func setThermal(_ level: ThermalLevel) {
        thermal = level
        glasses?.setThermalLevel(level)
    }

    func simulateCaptureFailure() { glasses?.services.cameraCapture.simulateCaptureFailure() }

    func denyCamera() {
        kit.permissions.set(.camera, .denied)
        kit.permissions.setRequestResult(.camera, result: .denied)
    }

    func grantCamera() {
        kit.permissions.set(.camera, .granted)
        kit.permissions.setRequestResult(.camera, result: .granted)
    }
}

/// MockDeviceKit plays only h.265. Converts anything else with AVFoundation.
enum MockVideoImporter {
    static func importAsHEVC(_ source: URL) async throws -> URL {
        let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("mock-feeds", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: source)

        if try await isHEVC(asset) {
            let dest = dir.appendingPathComponent("\(base).\(source.pathExtension.isEmpty ? "mp4" : source.pathExtension)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        }

        let dest = dir.appendingPathComponent("\(base)-hevc.mp4")
        try? FileManager.default.removeItem(at: dest)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        if #available(iOS 18.0, *) {
            try await export.export(to: dest, as: .mp4)
        } else {
            export.outputURL = dest
            export.outputFileType = .mp4
            await export.export()
            if let error = export.error { throw error }
        }
        return dest
    }

    private static func isHEVC(_ asset: AVURLAsset) async throws -> Bool {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let formats = try await track.load(.formatDescriptions)
        return formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
    }
}
#endif
