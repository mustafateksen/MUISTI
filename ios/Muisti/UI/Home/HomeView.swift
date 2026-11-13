import SwiftUI

/// "Kayıt" tab: what Muisti is doing, the last thing it saw, and one big button.
struct HomeView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController

    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @State private var showSettings = false
    @State private var showDeveloper = false
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
            .background(alignment: .top) {
                Theme.headerGradient
                    .frame(height: 360)
                    .ignoresSafeArea()
            }
            .navigationTitle("Muisti")
            .toolbar {
                if developerMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Geliştirici", systemImage: "hammer") { showDeveloper = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ayarlar", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(controller: controller, config: config, wearables: wearables)
            }
            .sheet(isPresented: $showDeveloper) {
                NavigationStack {
                    DeveloperView(controller: controller, config: config, wearables: wearables, showsDoneButton: true)
                }
            }
            .onChange(of: wearables.registrationState) { _, newState in
                // Back from Meta AI: continue where the user left off.
                guard newState == .registered, controller.isRunning, controller.state == .needsRegistration else { return }
                Task { await controller.start() }
            }
            .alert("Kamera izni", isPresented: $confirmPermission) {
                Button("Meta AI'a geç", action: requestGlassesPermission)
                Button("Telefon kamerasını kullan", action: switchToPhoneCamera)
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Muisti gözlüğün kamerasıyla tabelaları ve yazıları kaydeder. İzin için Meta AI uygulaması açılacak, onay verince buraya döneceksin.")
            }
        }
    }

    private func requestGlassesPermission() {
        Task { await controller.glasses.requestPermissionAndStart(using: wearables) }
    }

    private func switchToPhoneCamera() {
        config.sourceKind = .phone
        Task { await controller.start() }
    }
}
