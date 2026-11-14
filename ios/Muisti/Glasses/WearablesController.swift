import Foundation
import MWDATCore
import Observation
import UIKit

/// Registration with Meta AI, the device list, camera permission and update prompts.
/// Per-session camera work lives in `GlassesCaptureSource`.
@Observable
@MainActor
final class WearablesController {
    private(set) var registrationState: RegistrationState
    private(set) var deviceIds: [DeviceIdentifier] = []
    private(set) var deviceNames: [DeviceIdentifier: String] = [:]
    private(set) var cameraPermission: PermissionStatus?
    private(set) var requiresFirmwareUpdate = false

    /// Last user-facing problem from registration / permission / navigation.
    var lastError: String?
    /// `RegistrationError.metaAINotInstalled` and friends: show an App Store button.
    private(set) var metaAIMissing = false

    var isRegistered: Bool { registrationState == .registered }

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var devicesTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
    @ObservationIgnored private var compatibility: [DeviceIdentifier: Compatibility] = [:]

    static let metaAIAppStoreURL = URL(string: "https://apps.apple.com/app/id1558240027")!

    init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        registrationState = wearables.registrationState
        deviceIds = wearables.devices

        registrationTask = Task { [weak self] in
            guard let stream = self?.wearables.registrationStateStream() else { return }
            for await state in stream {
                guard let self else { return }
                self.registrationState = state
                if state == .registered {
                    self.metaAIMissing = false
                    await self.refreshCameraPermission()
                }
            }
        }
        devicesTask = Task { [weak self] in
            guard let stream = self?.wearables.devicesStream() else { return }
            for await ids in stream {
                guard let self else { return }
                self.deviceIds = ids
                self.trackCompatibility(ids)
            }
        }
    }

    isolated deinit {
        registrationTask?.cancel()
        devicesTask?.cancel()
    }

    // MARK: Registration

    /// Switches to Meta AI; comes back through `muisti://` (see `MuistiApp.onOpenURL`).
    func register() async {
        guard registrationState != .registering else { return }
        lastError = nil
        do {
            try await wearables.startRegistration()
        } catch {
            handle(registrationError: error)
        }
    }

    func unregister() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            if error == .metaAINotInstalled { metaAIMissing = true }
            lastError = error.description
        }
    }

    func handleOpenURL(_ url: URL) async {
        do {
            _ = try await wearables.handleUrl(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(registrationError error: RegistrationError) {
        switch error {
        case .metaAINotInstalled:
            metaAIMissing = true
            lastError = "The Meta AI app isn't installed. Install it first to connect your glasses."
        case .networkUnavailable:
            lastError = "Connecting needs internet. Check your connection and try again."
        case .alreadyRegistered:
            lastError = nil
        default:
            lastError = error.description
        }
    }

    // MARK: Camera permission

    /// Silent query; never leaves the app.
    @discardableResult
    func refreshCameraPermission() async -> PermissionStatus? {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            cameraPermission = status
            return status
        } catch {
            // `.noDevice` etc.: no answer yet, not a denial.
            cameraPermission = nil
            return nil
        }
    }

    /// Switches to Meta AI. Only call after telling the user why.
    func requestCameraPermission() async -> Bool {
        lastError = nil
        do {
            let status = try await wearables.requestPermission(.camera)
            cameraPermission = status
            if status != .granted { lastError = "Camera access wasn't granted. You can switch to the iPhone camera." }
            return status == .granted
        } catch {
            if error == .metaAINotInstalled { metaAIMissing = true }
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Updates

    func openFirmwareUpdate() async {
        do { try await wearables.openFirmwareUpdate() } catch { lastError = error.description }
    }

    func openGlassesAppUpdate() async {
        do { try await wearables.openDATGlassesAppUpdate() } catch { lastError = error.description }
    }

    private func trackCompatibility(_ ids: [DeviceIdentifier]) {
        let present = Set(ids)
        compatibilityTokens = compatibilityTokens.filter { present.contains($0.key) }
        compatibility = compatibility.filter { present.contains($0.key) }
        deviceNames = deviceNames.filter { present.contains($0.key) }

        for id in ids where compatibilityTokens[id] == nil {
            guard let device = wearables.deviceForIdentifier(id) else { continue }
            deviceNames[id] = device.nameOrId()
            compatibility[id] = device.compatibility()
            compatibilityTokens[id] = device.addCompatibilityListener { [weak self] value in
                Task { @MainActor in
                    self?.compatibility[id] = value
                    self?.updateFirmwareFlag()
                }
            }
        }
        updateFirmwareFlag()
    }

    private func updateFirmwareFlag() {
        requiresFirmwareUpdate = compatibility.values.contains(.deviceUpdateRequired)
    }
}

extension RegistrationState {
    var label: String {
        switch self {
        case .unavailable: return "unavailable"
        case .available: return "not connected"
        case .registering: return "connecting"
        case .registered: return "connected"
        @unknown default: return "unknown"
        }
    }
}
