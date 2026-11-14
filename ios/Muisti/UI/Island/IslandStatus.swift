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
                ("eyeglasses", .attention, "Glasses not connected", "Just approve Muisti once in the Meta AI app.", .register, true)
        case .needsRegistration:
            (symbol, tint, title, message, action, persistent) =
                ("link", .attention, "Connect your glasses", "Approve Muisti in the Meta AI app.", .register, true)
        case .needsPermission:
            (symbol, tint, title, message, action, persistent) =
                ("camera.badge.ellipsis", .attention, "Camera access needed", "Allow glasses camera access in Meta AI.", .permission, true)
        case .failed(let error):
            (symbol, tint, title, message, action, persistent) =
                ("exclamationmark.triangle.fill", .danger, "Something went wrong", error, .retry, true)
        case .waitingForDevice:
            (symbol, tint, title, message, action, persistent) =
                ("antenna.radiowaves.left.and.right", .attention, "Waiting for glasses",
                 controller.isRunning ? glasses.waitingHint : "Make sure your glasses are on, unfolded, and near your phone.", nil, true)
        case .paused(let reason):
            (symbol, tint, title, message, action, persistent) =
                ("pause.circle.fill", .attention, "Paused", reason, controller.isRunning ? .resume : .start, true)
        case .starting:
            (symbol, tint, title, message, action, persistent) =
                ("hourglass", .attention, "Connecting", usesGlasses ? "Connecting to your glasses' camera…" : "Opening the iPhone camera…", nil, false)
        case .running:
            if let warning {
                (symbol, tint, title, message, action, persistent) =
                    ("exclamationmark.triangle.fill", .attention, "Recording, with a warning", warning, nil, true)
            } else if let battery, battery < 15, !charging {
                (symbol, tint, title, message, action, persistent) =
                    ("battery.25percent", .attention, "Glasses battery low", "Battery at \(battery)%. You'll need to charge soon.", nil, false)
            } else {
                (symbol, tint, title, message, action, persistent) =
                    (sourceSymbol, .success, "Remembering", "Saving the signs and text you see.", .stop, false)
            }
        case .idle:
            (symbol, tint, title, message, action, persistent) =
                (sourceSymbol, .secondary, "Recording off", "Start recording and I'll remember the signs, numbers, and times you see.", .start, false)
        }
        key = "\(title)|\(message)"
    }
}
