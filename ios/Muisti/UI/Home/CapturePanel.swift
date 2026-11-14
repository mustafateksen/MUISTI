import SwiftUI

/// Glasses and recording details, opened from the island: status, setup steps,
/// start/stop, and the last frame seen.
struct CapturePanel: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController

    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var confirmPermission = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.m) {
                    StatusCard(status: HomeStatus(controller: controller, config: config, wearables: wearables))
                    SetupCards(
                        controller: controller,
                        config: config,
                        wearables: wearables,
                        askForPermission: { confirmPermission = true },
                        openSettings: { showSettings = true }
                    )
                    RecordControls(controller: controller)
                    PreviewView(
                        image: controller.previewImage,
                        state: controller.state,
                        lastFrame: controller.lastFrame,
                        mode: config.mode
                    )
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.l)
                .animation(Theme.Motion.standard, value: controller.state)
            }
            .navigationTitle("Glasses and recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(controller: controller, config: config, wearables: wearables)
            }
            .glassesPermissionAlert(isPresented: $confirmPermission, controller: controller, config: config, wearables: wearables)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
