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
                row("exclamationmark.triangle", error).foregroundStyle(.orange)
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
        case .running: return .green
        case .starting, .waitingForDevice: return .yellow
        case .paused: return .orange
        case .failed, .needsPermission, .needsRegistration: return .red
        case .idle: return .gray
        }
    }

    private var sourceLabel: String {
        if config.sourceKind == .phone { return "Telefon" }
        return MockRuntime.isActive ? "Sahte gözlük" : "Gözlük"
    }

    private var glassesLine: String {
        var parts = ["kayıt: \(wearables.registrationState.label)", "oturum: \(glasses.sessionState.description)"]
        if config.mode.usesPhotoCapability {
            parts.append("foto: \(String(describing: glasses.photoState))")
            if let res = glasses.effectiveStillResolution { parts.append(res) }
            if let ms = glasses.lastTransferMillis { parts.append("aktarım \(ms) ms") }
            if let fraction = glasses.transferFraction { parts.append("%\(Int(fraction * 100))") }
        } else {
            parts.append("akış: \(String(describing: glasses.streamState))")
        }
        return parts.joined(separator: " · ")
    }

    private var deviceLine: String {
        let d = glasses.device
        guard glasses.hasActiveDevice else { return "Cihaz yok" }
        var parts = [d.name.isEmpty ? "Gözlük" : d.name]
        if let battery = d.battery { parts.append("pil %\(battery)\(d.charging == .charging ? "⚡︎" : "")") }
        switch d.don {
        case .donned: parts.append("takılı")
        case .doffed: parts.append("takılı değil")
        default: break
        }
        if d.hinge == .closed { parts.append("menteşe kapalı") }
        switch d.thermal {
        case .moderate: parts.append("ılık")
        case .severe: parts.append("sıcak")
        case .critical, .emergency, .shutdown: parts.append("aşırı sıcak")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var schedulerLine: String {
        var parts = [
            "\(controller.motion.activity.label) → \(controller.movement.label)",
            controller.schedulerText,
            "\(controller.capturesLastMinute)/dk",
        ]
        if controller.batteryFactor > 1 { parts.append(String(format: "tasarruf ×%.1f", controller.batteryFactor)) }
        return parts.joined(separator: " · ")
    }

    private var locationLine: String {
        guard let fix = controller.location.freshFix() else {
            return controller.location.isRunning ? "Konum bekleniyor" : "Konum kapalı"
        }
        var parts = [String(format: "±%.0f m", fix.accuracy)]
        if let speed = fix.validSpeed { parts.append(String(format: "%.1f m/sn", speed)) }
        if let course = fix.validCourse { parts.append(String(format: "yön %.0f°", course)) }
        parts.append(String(format: "%.0f m yol", controller.location.odometer))
        if controller.motion.stepCount > 0 { parts.append("\(controller.motion.stepCount) adım") }
        return parts.joined(separator: " · ")
    }

    private var queueLine: String {
        let q = controller.queueStatus
        var parts = ["alınan \(controller.capturedCount)", "tutulan \(controller.keptCount)"]
        if !q.enabled {
            parts.append("yükleme kapalı")
        } else {
            parts.append("bekleyen \(q.pending)")
            parts.append("gönderilen \(q.sent)")
            if !q.online { parts.append("çevrimdışı") }
        }
        if let folder = controller.recordingFolder { parts.append("diske: \(folder)") }
        return parts.joined(separator: " · ")
    }

    private var currentError: String? {
        if config.sourceKind == .glasses, controller.isRunning, controller.state == .waitingForDevice {
            return glasses.waitingHint
        }
        if config.sourceKind == .glasses, let e = glasses.lastError { return e }
        if config.sourceKind == .glasses, let w = glasses.healthWarning { return w }
        if let e = wearables.lastError { return e }
        if let e = controller.queueStatus.lastError, controller.queueStatus.enabled { return e }
        return nil
    }
}
