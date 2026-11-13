import SwiftUI

/// Next-step cards: connect the glasses, grant camera access, update firmware, add the AI key.
struct SetupCards: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController
    let askForPermission: () -> Void
    let openSettings: () -> Void

    private var glasses: GlassesCaptureSource { controller.glasses }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if config.sourceKind == .glasses {
                if !wearables.isRegistered {
                    ActionCard(
                        icon: "eyeglasses",
                        title: "Gözlüğü bağla",
                        message: "Meta AI uygulamasına geçip Muisti'yi onaylayacaksın, sonra buraya döneceksin. İnternet gerekli.",
                        button: wearables.registrationState == .registering ? "Bağlanıyor…" : "Bağlan",
                        action: register
                    )
                    if wearables.metaAIMissing {
                        Link("Meta AI'ı App Store'da aç", destination: WearablesController.metaAIAppStoreURL)
                            .font(.footnote.weight(.semibold))
                    }
                } else if controller.state == .needsPermission {
                    ActionCard(
                        icon: "camera.badge.ellipsis",
                        title: "Kamera izni gerekli",
                        message: "Gözlük kamerasına erişim için Meta AI'da izin vermelisin.",
                        button: "İzin ver",
                        action: askForPermission
                    )
                }
                if wearables.requiresFirmwareUpdate {
                    ActionCard(
                        icon: "arrow.down.circle",
                        title: "Gözlük yazılımı eski",
                        message: "Güncelleme Meta AI uygulamasında yapılır.",
                        button: "Güncelle",
                        tint: .orange,
                        action: openFirmwareUpdate
                    )
                }
                if glasses.needsGlassesAppUpdate {
                    ActionCard(
                        icon: "arrow.down.app",
                        title: "Gözlükteki uygulama eski",
                        message: "Güncelleme Meta AI uygulamasında yapılır.",
                        button: "Güncelle",
                        tint: .orange,
                        action: openGlassesAppUpdate
                    )
                }
            }
            if !controller.enrichment.hasKey {
                ActionCard(
                    icon: "sparkles",
                    title: "Yapay zekâyı aç",
                    message: "Anahtar eklenince kayıtlar ad, telefon ve saat olarak düzenlenir; sorulara daha iyi cevap verilir. O zamana kadar kayıtlar telefonda bekler.",
                    button: "Ayarlar'a git",
                    tint: .purple,
                    action: openSettings
                )
            }
        }
    }

    private func register() {
        Task { await wearables.register() }
    }

    private func openFirmwareUpdate() {
        Task { await wearables.openFirmwareUpdate() }
    }

    private func openGlassesAppUpdate() {
        Task { await wearables.openGlassesAppUpdate() }
    }
}
