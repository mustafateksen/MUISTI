import SwiftUI

/// Everything a developer or tester needs and an end user should not see: live diagnostics,
/// capture modes (A/B/C), the Nemotron endpoint, stream/photo parameters, adaptive scheduler
/// tuning, the raw dataset switch and (DEBUG) the mock glasses.
///
/// Shown as a sheet from the Kayıt toolbar, or pushed from Settings > Gelişmiş.
struct DeveloperView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController
    /// True when this panel is the root of its own sheet (not pushed from Settings).
    var showsDoneButton = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Canlı durum") {
                StatusBanner(controller: controller, config: config, wearables: wearables)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            DeveloperCaptureSection(controller: controller, config: config)
            NemotronDeveloperSection(controller: controller, config: config)
            CaptureParametersSection(config: config)
            AdaptiveTuningSection(config: config)

            Section {
                Toggle("Ham kareleri de kaydet", isOn: $config.recordToDisk)
                Text("Dosyalar > Bu iPhone'da > Muisti > sessions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Veri seti")
            } footer: {
                Text("Yalnızca gözlük penceresi için veri seti. Kapalıyken ham kare saklanmaz.")
            }

            #if DEBUG
            Section {
                NavigationLink(value: DeveloperRoute.mockDevice) {
                    Label("Sahte gözlük (MockDeviceKit)", systemImage: "eyeglasses.slash")
                }
            } header: {
                Text("Simülasyon")
            } footer: {
                Text("Simülatörde gözlüksüz deneme: tabela videosu, menteşe, pil, ısı ve hata senaryoları.")
            }
            #endif
        }
        .navigationTitle("Geliştirici")
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
                    Button("Bitti") { dismiss() }
                }
            }
        }
        .onDisappear(perform: applySettings)
    }

    private func applySettings() {
        Task { await controller.applySettings() }
    }
}
