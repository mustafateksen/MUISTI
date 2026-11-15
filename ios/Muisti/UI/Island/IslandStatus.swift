import SwiftUI

/// What the glasses island shows: a compact icon + dot, and an expanded sentence with one action.
/// `key` changes whenever the situation changes; the island expands on every change, stays open
/// while `persistent` (something is wrong), and shrinks again once it is resolved.
@MainActor
struct IslandStatus: Equatable {
    let key: String
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let action: IslandAction?
    /// Stays expanded until resolved (or the user closes it).
    let persistent: Bool
    let isRecording: Bool
    /// Short trailing text in the compact island, e.g. "82%".
    let badge: String?

    init(controller: CaptureController, config: AppConfig, wearables: WearablesController) {
        // A staged screen (remote driver, for a video): the status is what the driver set,
        // whatever the glasses are really doing.
        if let staged = UserDefaults.standard.string(forKey: DeveloperMode.stageStatusKey) {
            let level = UserDefaults.standard.integer(forKey: DeveloperMode.stageBatteryKey)
            badge = level > 0 ? "\(level)%" : nil
            isRecording = staged == "recording"
            if isRecording {
                (symbol, tint, title, message, action, persistent) =
                    ("eyeglasses", .success, String(localized: "Remembering"), String(localized: "Saving the signs and text you see."), nil, false)
            } else {
                (symbol, tint, title, message, action, persistent) =
                    ("eyeglasses", .secondary, String(localized: "Recording off"), String(localized: "Start recording and I'll remember the signs, numbers, and times you see."), nil, false)
            }
            key = "\(title)|\(message)"
            return
        }
        let glasses = controller.glasses
        let usesGlasses = config.sourceKind == .glasses
        let sourceSymbol = usesGlasses ? "eyeglasses" : "iphone.rear.camera"
        let device = glasses.device
        let battery = usesGlasses && glasses.hasActiveDevice ? device.battery : nil
        let charging = device.charging == .charging
        badge = battery.map { "\($0)%" }
        isRecording = controller.state == .running

        let warning: String? = usesGlasses ? (glasses.lastError ?? glasses.healthWarning ?? wearables.lastError) : nil

        switch controller.state {
        case _ where usesGlasses && !wearables.isRegistered:
            (symbol, tint, title, message, action, persistent) =
                ("eyeglasses", .attention, String(localized: "Glasses not connected"), String(localized: "Just approve Muisti once in the Meta AI app."), .register, true)
        case .needsRegistration:
            (symbol, tint, title, message, action, persistent) =
                ("link", .attention, String(localized: "Connect your glasses"), String(localized: "Approve Muisti in the Meta AI app."), .register, true)
        case .needsPermission:
            (symbol, tint, title, message, action, persistent) =
                ("camera.badge.ellipsis", .attention, String(localized: "Camera access needed"), String(localized: "Allow glasses camera access in Meta AI."), .permission, true)
        case .failed(let error):
            (symbol, tint, title, message, action, persistent) =
                ("exclamationmark.triangle.fill", .danger, String(localized: "Something went wrong"), error, .retry, true)
        case .waitingForDevice:
            (symbol, tint, title, message, action, persistent) =
                ("antenna.radiowaves.left.and.right", .attention, String(localized: "Waiting for glasses"),
                 controller.isRunning ? glasses.waitingHint : String(localized: "Make sure your glasses are on, unfolded, and near your phone."), nil, true)
        case .paused(let reason):
            (symbol, tint, title, message, action, persistent) =
                ("pause.circle.fill", .attention, String(localized: "Paused"), reason, controller.isRunning ? .resume : .start, true)
        case .starting:
            (symbol, tint, title, message, action, persistent) =
                ("hourglass", .attention, String(localized: "Connecting"), usesGlasses ? String(localized: "Connecting to your glasses' camera…") : String(localized: "Opening the iPhone camera…"), nil, false)
        case .running:
            if let warning {
                (symbol, tint, title, message, action, persistent) =
                    ("exclamationmark.triangle.fill", .attention, String(localized: "Recording, with a warning"), warning, nil, true)
            } else if let battery, battery < 15, !charging {
                (symbol, tint, title, message, action, persistent) =
                    ("battery.25percent", .attention, String(localized: "Glasses battery low"), String(localized: "Battery at \(battery)%. You'll need to charge soon."), nil, false)
            } else {
                (symbol, tint, title, message, action, persistent) =
                    (sourceSymbol, .success, String(localized: "Remembering"), String(localized: "Saving the signs and text you see."), .stop, false)
            }
        case .idle:
            (symbol, tint, title, message, action, persistent) =
                (sourceSymbol, .secondary, String(localized: "Recording off"), String(localized: "Start recording and I'll remember the signs, numbers, and times you see."), .start, false)
        }
        key = "\(title)|\(message)"
    }
}
