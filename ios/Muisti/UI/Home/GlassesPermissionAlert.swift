import SwiftUI

/// "Camera access" choice: grant it in Meta AI, or fall back to the phone camera.
struct GlassesPermissionAlert: ViewModifier {
    @Binding var isPresented: Bool
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController

    func body(content: Content) -> some View {
        content.alert("Camera access", isPresented: $isPresented) {
            Button("Open Meta AI") {
                Task { await controller.glasses.requestPermissionAndStart(using: wearables) }
            }
            Button("Use iPhone camera") {
                config.sourceKind = .phone
                Task { await controller.start() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Muisti uses your glasses' camera to save signs and text. The Meta AI app will open so you can allow access, then you'll come back here.")
        }
    }
}

extension View {
    func glassesPermissionAlert(isPresented: Binding<Bool>, controller: CaptureController, config: AppConfig, wearables: WearablesController) -> some View {
        modifier(GlassesPermissionAlert(isPresented: isPresented, controller: controller, config: config, wearables: wearables))
    }
}
