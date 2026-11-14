import CoreLocation
import SwiftUI

/// Plain-language summary of what Muisti is doing right now, for the end-user status card.
/// Technical detail (session/stream states, scheduler, transfer times) lives in the developer panel.
@MainActor
struct HomeStatus {
    enum Tone {
        case idle, active, waiting, attention, problem

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .active: return .success
            case .waiting: return .attention
            case .attention: return .attention
            case .problem: return .danger
            }
        }
    }

    struct Chip: Identifiable {
        let id: String
        let text: String
        let systemImage: String
        var tint: Color = .secondary
    }

    let title: String
    let message: String
    let symbol: String
    let tone: Tone
    let chips: [Chip]
    /// One short warning worth showing to a normal user, if any.
    let warning: String?

    init(controller: CaptureController, config: AppConfig, wearables: WearablesController) {
        let glasses = controller.glasses
        let usesGlasses = config.sourceKind == .glasses
        let running = controller.isRunning

        switch controller.state {
        case .running:
            title = String(localized: "Remembering")
            message = config.mode.usesScheduler
                ? String(localized: "I'm saving the signs and text you see when it matters. Keep Muisti open; the screen won't lock.")
                : String(localized: "Continuous recording is on. Text you see is being added to your memory.")
            symbol = usesGlasses ? "eyeglasses" : "iphone.rear.camera"
            tone = .active
        case .starting:
            title = String(localized: "Starting")
            message = usesGlasses ? String(localized: "Connecting to your glasses' camera…") : String(localized: "Opening the iPhone camera…")
            symbol = "hourglass"
            tone = .waiting
        case .waitingForDevice:
            title = String(localized: "Waiting for glasses")
            message = running ? glasses.waitingHint : String(localized: "Make sure your glasses are on, unfolded, and near your phone.")
            symbol = "antenna.radiowaves.left.and.right"
            tone = .waiting
        case .paused(let reason):
            title = String(localized: "Paused")
            message = reason
            symbol = "pause.circle"
            tone = .attention
        case .needsRegistration:
            title = String(localized: "Connect your glasses")
            message = String(localized: "Just approve Muisti once in the Meta AI app.")
            symbol = "link"
            tone = .attention
        case .needsPermission:
            title = String(localized: "Camera access needed")
            message = String(localized: "Allow access in Meta AI to use the glasses camera.")
            symbol = "camera.badge.ellipsis"
            tone = .attention
        case .failed(let error):
            title = String(localized: "Something went wrong")
            message = error
            symbol = "exclamationmark.triangle"
            tone = .problem
        case .idle:
            title = String(localized: "Ready")
            message = String(localized: "Start recording and I'll remember the signs, numbers, and times you see as you walk.")
            symbol = usesGlasses ? "eyeglasses" : "iphone.rear.camera"
            tone = .idle
        }

        var chips: [Chip] = []
        if usesGlasses {
            if glasses.hasActiveDevice {
                let device = glasses.device
                let name = device.name.isEmpty ? String(localized: "Glasses") : device.name
                if let battery = device.battery {
                    let charging = device.charging == .charging
                    chips.append(Chip(
                        id: "device",
                        text: "\(name) \(battery)%",
                        systemImage: charging ? "battery.100percent.bolt" : Self.batterySymbol(battery),
                        tint: battery < 20 && !charging ? .attention : .success
                    ))
                } else {
                    chips.append(Chip(id: "device", text: name, systemImage: "eyeglasses", tint: .success))
                }
            } else {
                chips.append(Chip(
                    id: "device",
                    text: wearables.isRegistered ? String(localized: "Glasses not found") : String(localized: "Glasses not connected"),
                    systemImage: "eyeglasses"
                ))
            }
        } else {
            chips.append(Chip(id: "device", text: String(localized: "iPhone camera"), systemImage: "iphone.rear.camera"))
        }

        switch controller.location.authorization {
        case .denied, .restricted:
            chips.append(Chip(id: "location", text: String(localized: "Location off"), systemImage: "location.slash", tint: .attention))
        default:
            if controller.location.freshFix() != nil {
                chips.append(Chip(id: "location", text: String(localized: "Location on"), systemImage: "location.fill", tint: .brandSky))
            }
        }

        chips.append(Chip(
            id: "memory",
            text: controller.memoryCount == 1
                ? String(localized: "\(controller.memoryCount) memory")
                : String(localized: "\(controller.memoryCount) memories"),
            systemImage: "square.stack.3d.up.fill",
            tint: .accentColor
        ))
        if !controller.enrichment.online {
            chips.append(Chip(id: "online", text: String(localized: "Offline"), systemImage: "wifi.slash", tint: .attention))
        } else if controller.pendingCount > 0 {
            chips.append(Chip(id: "pending", text: String(localized: "\(controller.pendingCount) processing"), systemImage: "sparkles"))
        }
        self.chips = chips

        if usesGlasses, let error = glasses.lastError {
            warning = error
        } else if usesGlasses, let health = glasses.healthWarning {
            warning = health
        } else if let error = wearables.lastError {
            warning = error
        } else {
            warning = nil
        }
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
