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
            case .active: return .green
            case .waiting: return .yellow
            case .attention: return .orange
            case .problem: return .red
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
            title = "Hatırlıyorum"
            message = config.mode.usesScheduler
                ? "Gördüğün tabela ve yazıları gerekli anlarda kaydediyorum. Muisti açık kalsın; ekran kilitlenmez."
                : "Sürekli kayıt açık. Gördüğün yazılar hafızaya ekleniyor."
            symbol = usesGlasses ? "eyeglasses" : "iphone.rear.camera"
            tone = .active
        case .starting:
            title = "Başlatılıyor"
            message = usesGlasses ? "Gözlüğün kamerasına bağlanıyorum…" : "Telefon kamerası açılıyor…"
            symbol = "hourglass"
            tone = .waiting
        case .waitingForDevice:
            title = "Gözlük bekleniyor"
            message = running ? glasses.waitingHint : "Gözlüğün açık, menteşesi açık ve telefona yakın olsun."
            symbol = "antenna.radiowaves.left.and.right"
            tone = .waiting
        case .paused(let reason):
            title = "Duraklatıldı"
            message = reason
            symbol = "pause.circle"
            tone = .attention
        case .needsRegistration:
            title = "Gözlüğü bağla"
            message = "Meta AI uygulamasında Muisti'yi bir kez onaylaman yeterli."
            symbol = "link"
            tone = .attention
        case .needsPermission:
            title = "Kamera izni gerekli"
            message = "Gözlük kamerasını kullanmak için Meta AI'da izin vermelisin."
            symbol = "camera.badge.ellipsis"
            tone = .attention
        case .failed(let error):
            title = "Bir sorun oluştu"
            message = error
            symbol = "exclamationmark.triangle"
            tone = .problem
        case .idle:
            title = "Hazır"
            message = "Kaydı başlat; yürürken gördüğün tabelaları, numaraları ve saatleri senin için hatırlayayım."
            symbol = usesGlasses ? "eyeglasses" : "iphone.rear.camera"
            tone = .idle
        }

        var chips: [Chip] = []
        if usesGlasses {
            if glasses.hasActiveDevice {
                let device = glasses.device
                let name = device.name.isEmpty ? "Gözlük" : device.name
                if let battery = device.battery {
                    let charging = device.charging == .charging
                    chips.append(Chip(
                        id: "device",
                        text: "\(name) %\(battery)",
                        systemImage: charging ? "battery.100percent.bolt" : Self.batterySymbol(battery),
                        tint: battery < 20 && !charging ? .orange : .green
                    ))
                } else {
                    chips.append(Chip(id: "device", text: name, systemImage: "eyeglasses", tint: .green))
                }
            } else {
                chips.append(Chip(
                    id: "device",
                    text: wearables.isRegistered ? "Gözlük bulunamadı" : "Gözlük bağlı değil",
                    systemImage: "eyeglasses"
                ))
            }
        } else {
            chips.append(Chip(id: "device", text: "Telefon kamerası", systemImage: "iphone.rear.camera"))
        }

        switch controller.location.authorization {
        case .denied, .restricted:
            chips.append(Chip(id: "location", text: "Konum kapalı", systemImage: "location.slash", tint: .orange))
        default:
            if controller.location.freshFix() != nil {
                chips.append(Chip(id: "location", text: "Konum açık", systemImage: "location.fill", tint: .blue))
            }
        }

        chips.append(Chip(
            id: "memory",
            text: "\(controller.memoryCount) anı",
            systemImage: "square.stack.3d.up.fill",
            tint: .accentColor
        ))
        if !controller.enrichment.online {
            chips.append(Chip(id: "online", text: "Çevrimdışı", systemImage: "wifi.slash", tint: .orange))
        } else if controller.pendingCount > 0 {
            chips.append(Chip(id: "pending", text: "\(controller.pendingCount) işleniyor", systemImage: "sparkles"))
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
