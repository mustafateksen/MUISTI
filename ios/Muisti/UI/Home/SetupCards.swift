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
                        title: String(localized: "Connect your glasses"),
                        message: String(localized: "You'll switch to the Meta AI app to approve Muisti, then come back here. Requires an internet connection."),
                        button: wearables.registrationState == .registering ? String(localized: "Connecting…") : String(localized: "Connect"),
                        action: register
                    )
                    if wearables.metaAIMissing {
                        Link("Open Meta AI in the App Store", destination: WearablesController.metaAIAppStoreURL)
                            .font(.footnote.weight(.semibold))
                    }
                } else if controller.state == .needsPermission {
                    ActionCard(
                        icon: "camera.badge.ellipsis",
                        title: String(localized: "Camera access needed"),
                        message: String(localized: "Allow access to the glasses camera in Meta AI."),
                        button: String(localized: "Allow", comment: "Button: grant glasses camera access"),
                        action: askForPermission
                    )
                }
                if wearables.requiresFirmwareUpdate {
                    ActionCard(
                        icon: "arrow.down.circle",
                        title: String(localized: "Glasses software out of date"),
                        message: String(localized: "Update it in the Meta AI app."),
                        button: String(localized: "Update"),
                        tint: .attention,
                        action: openFirmwareUpdate
                    )
                }
                if glasses.needsGlassesAppUpdate {
                    ActionCard(
                        icon: "arrow.down.app",
                        title: String(localized: "App on glasses out of date"),
                        message: String(localized: "Update it in the Meta AI app."),
                        button: String(localized: "Update"),
                        tint: .attention,
                        action: openGlassesAppUpdate
                    )
                }
            }
            if !controller.enrichment.hasKey {
                ActionCard(
                    icon: "sparkles",
                    title: String(localized: "Turn on AI"),
                    message: String(localized: "Once you add a key, recordings are organized into names, phone numbers, and times, and questions get better answers. Until then, recordings wait on your phone."),
                    button: String(localized: "Go to Settings"),
                    tint: .brandBlue,
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
