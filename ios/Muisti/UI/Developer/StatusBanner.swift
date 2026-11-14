import MWDATCamera
import MWDATCore
import SwiftUI

/// Always-visible status block: source, session/stream state, battery, location/motion,
/// queue length and the last error.
struct StatusBanner: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController

    private var glasses: GlassesCaptureSource { controller.glasses }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(controller.state.label).font(.subheadline.weight(.semibold)).lineLimit(3)
                Spacer()
                Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
            }
            if config.sourceKind == .glasses {
                row("eyeglasses", glassesLine)
                row("battery.75percent", deviceLine)
            }
            if controller.isRunning, config.mode.usesScheduler {
                row("figure.walk", schedulerLine)
            }
            row("location", locationLine)
            row("tray.and.arrow.up", queueLine)
            if let error = currentError {
                row("exclamationmark.triangle", error).foregroundStyle(.attention)
            }
        }
        .font(.caption)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).lineLimit(3)
        } icon: {
            Image(systemName: icon).frame(width: 18)
        }
    }

    private var stateColor: Color {
        switch controller.state {
        case .running: return .success
        case .starting, .waitingForDevice: return .attention
        case .paused: return .attention
        case .failed, .needsPermission, .needsRegistration: return .danger
        case .idle: return .gray
        }
    }

    private var sourceLabel: String {
        if config.sourceKind == .phone { return "iPhone" }
        return MockRuntime.isActive ? "Mock glasses" : "Glasses"
    }

    private var glassesLine: String {
        var parts = ["registration: \(wearables.registrationState.label)", "session: \(glasses.sessionState.description)"]
        if config.mode.usesPhotoCapability {
            parts.append("photo: \(String(describing: glasses.photoState))")
            if let res = glasses.effectiveStillResolution { parts.append(res) }
            if let ms = glasses.lastTransferMillis { parts.append("transfer \(ms) ms") }
            if let fraction = glasses.transferFraction { parts.append("\(Int(fraction * 100))%") }
        } else {
            parts.append("stream: \(String(describing: glasses.streamState))")
        }
        return parts.joined(separator: " · ")
    }

    private var deviceLine: String {
        let d = glasses.device
        guard glasses.hasActiveDevice else { return "No device" }
        var parts = [d.name.isEmpty ? "Glasses" : d.name]
        if let battery = d.battery { parts.append("battery \(battery)%\(d.charging == .charging ? "⚡︎" : "")") }
        switch d.don {
        case .donned: parts.append("worn")
        case .doffed: parts.append("not worn")
        default: break
        }
        if d.hinge == .closed { parts.append("hinge closed") }
        switch d.thermal {
        case .moderate: parts.append("warm")
        case .severe: parts.append("hot")
        case .critical, .emergency, .shutdown: parts.append("overheated")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var schedulerLine: String {
        var parts = [
            "\(controller.motion.activity.label) → \(controller.movement.label)",
            controller.schedulerText,
            "\(controller.capturesLastMinute)/min",
        ]
        if controller.batteryFactor > 1 { parts.append(String(format: "saver ×%.1f", controller.batteryFactor)) }
        return parts.joined(separator: " · ")
    }

    private var locationLine: String {
        guard let fix = controller.location.freshFix() else {
            switch controller.location.authorization {
            case .denied, .restricted:
                return "No location permission: frames are saved without location. Settings > Muisti > Location."
            default:
                return controller.location.isRunning ? "Waiting for location" : "Location off"
            }
        }
        var parts = [String(format: "±%.0f m", fix.accuracy)]
        if let speed = fix.validSpeed { parts.append(String(format: "%.1f m/s", speed)) }
        if let course = fix.validCourse { parts.append(String(format: "heading %.0f°", course)) }
        parts.append(String(format: "%.0f m traveled", controller.location.odometer))
        if controller.motion.stepCount > 0 { parts.append("\(controller.motion.stepCount) steps") }
        return parts.joined(separator: " · ")
    }

    private var queueLine: String {
        let stats = controller.pipelineStats
        var parts = ["captured \(controller.capturedCount)", "in memory \(controller.memoryCount)"]
        if controller.pendingCount > 0 { parts.append("Nemotron pending \(controller.pendingCount)") }
        if stats.droppedTotal > 0 { parts.append("dropped \(stats.droppedTotal) (\(stats.droppedSummary))") }
        if !controller.enrichment.online { parts.append("offline") }
        if let folder = controller.recordingFolder { parts.append("raw: \(folder)") }
        return parts.joined(separator: " · ")
    }

    private var currentError: String? {
        if config.sourceKind == .glasses, controller.isRunning, controller.state == .waitingForDevice {
            return glasses.waitingHint
        }
        if config.sourceKind == .glasses, let e = glasses.lastError { return e }
        if config.sourceKind == .glasses, let w = glasses.healthWarning { return w }
        if let e = wearables.lastError { return e }
        if !controller.enrichment.hasKey, controller.memoryCount > 0 {
            return "No Nemotron API key: frames are waiting on the iPhone (Settings > AI)."
        }
        if let e = controller.enrichment.lastError { return e }
        return nil
    }
}
