import SwiftUI

/// Everything a developer or tester needs and an end user should not see: live diagnostics,
/// capture modes (A/B/C), the Nemotron endpoint, stream/photo parameters, adaptive scheduler
/// tuning, the raw dataset switch and (DEBUG) the mock glasses.
///
/// Shown as a sheet from the Recording toolbar, or pushed from Settings > Advanced.
struct DeveloperView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController
    /// True when this panel is the root of its own sheet (not pushed from Settings).
    var showsDoneButton = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Live status") {
                StatusBanner(controller: controller, config: config, wearables: wearables)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            DeveloperCaptureSection(controller: controller, config: config)
            NemotronDeveloperSection(controller: controller, config: config)
            CaptureParametersSection(config: config)
            AdaptiveTuningSection(config: config)

            Section {
                Toggle("Also save raw frames", isOn: $config.recordToDisk)
                Text("Files > On My iPhone > Muisti > sessions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Dataset")
            } footer: {
                Text("Dataset for the glasses window only. When off, no raw frames are stored.")
            }

            #if DEBUG
            Section {
                NavigationLink(value: DeveloperRoute.mockDevice) {
                    Label("Mock glasses (MockDeviceKit)", systemImage: "eyeglasses.slash")
                }
            } header: {
                Text("Simulation")
            } footer: {
                Text("Test without glasses in the Simulator: sign video, hinge, battery, heat and error scenarios.")
            }
            #endif
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DeveloperRoute.self) { route in
            switch route {
            case .mockDevice:
                #if DEBUG
                DebugMenu(controller: controller, mock: controller.mock)
                #else
                EmptyView()
                #endif
            }
        }
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear(perform: applySettings)
    }

    private func applySettings() {
        Task { await controller.applySettings() }
    }
}
