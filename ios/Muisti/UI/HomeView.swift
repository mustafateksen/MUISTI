import SwiftUI

struct HomeView: View {
    @Bindable var controller: CaptureController
    @Bindable var config: AppConfig
    @Bindable var wearables: WearablesController

    @State private var showSettings = false
    @State private var showDebug = false
    @State private var confirmPermission = false

    private var glasses: GlassesCaptureSource { controller.glasses }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusBanner(controller: controller, config: config, wearables: wearables)
                    PreviewView(
                        image: controller.previewImage,
                        state: controller.state,
                        lastFrame: controller.lastFrame,
                        mode: config.mode
                    )
                    actionCards
                    controls
                    sourcePickers
                }
                .padding(16)
            }
            .navigationTitle("Muisti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Ayarlar")
                }
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDebug = true } label: { Image(systemName: "ladybug") }
                        .accessibilityLabel("Hata ayıklama")
                }
                #endif
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(controller: controller, config: config)
            }
            #if DEBUG
            .sheet(isPresented: $showDebug) {
                DebugMenu(controller: controller, mock: controller.mock)
            }
            #endif
            #if DEBUG
            .task {
                // `--mock-autostart`: simulator demo without touching anything.
                guard ProcessInfo.processInfo.arguments.contains("--mock-autostart") else { return }
                controller.mock.quickStart()
                config.sourceKind = .glasses
                if let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mode=") }) {
                    config.mode = CaptureMode(rawValue: String(mode.dropFirst(7))) ?? config.mode
                }
                if let server = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--server=") }) {
                    config.serverBaseURL = String(server.dropFirst(9))
                }
                try? await Task.sleep(for: .seconds(1))
                await controller.start()
                // `--mock-script=fold@8,unfold@14,doff@22,don@28,tap@34,tap@38`
                if let script = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mock-script=") }) {
                    await runMockScript(String(script.dropFirst(14)))
                }
            }
            #endif
            .alert("Kamera izni", isPresented: $confirmPermission) {
                Button("Meta AI'a geç") {
                    Task { await glasses.requestPermissionAndStart(using: wearables) }
                }
                Button("Telefon kamerasını kullan") {
                    config.sourceKind = .phone
                    Task { await controller.start() }
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Muisti gözlüğün kamerasıyla tabelaları ve yazıları kaydeder. İzin için Meta AI uygulaması açılacak, onay verince buraya döneceksin.")
            }
        }
    }

    #if DEBUG
    private func runMockScript(_ script: String) async {
        let start = Date()
        for step in script.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let wait = at - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            Log.mock.info("script: \(String(parts[0]), privacy: .public)")
            switch parts[0] {
            case "fold": controller.mock.setUnfolded(false)
            case "unfold": controller.mock.setUnfolded(true)
            case "doff": controller.mock.setDonned(false)
            case "don": controller.mock.setDonned(true)
            case "tap": controller.mock.tap()
            case "battery5": controller.mock.setBattery(5)
            case "hot": controller.mock.setThermal(.severe)
            case "deny": controller.mock.denyCamera()
            case "background": NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            default: break
            }
        }
    }
    #endif

    // MARK: Cards that ask the user for one next step

    @ViewBuilder
    private var actionCards: some View {
        if config.sourceKind == .glasses {
            if !wearables.isRegistered {
                ActionCard(
                    icon: "eyeglasses",
                    title: "Gözlüğü bağla",
                    message: "Meta AI uygulamasına geçip Muisti'yi onaylayacaksın. İnternet gerekli.",
                    button: wearables.registrationState == .registering ? "Bağlanıyor…" : "Bağlan"
                ) {
                    Task { await wearables.register() }
                }
                if wearables.metaAIMissing {
                    Link("Meta AI'ı App Store'da aç", destination: WearablesController.metaAIAppStoreURL)
                        .font(.footnote.weight(.semibold))
                }
            } else if controller.state == .needsPermission {
                ActionCard(
                    icon: "camera.badge.ellipsis",
                    title: "Kamera izni gerekli",
                    message: "Gözlük kamerasına erişim için Meta AI'da izin vermelisin.",
                    button: "İzin ver"
                ) { confirmPermission = true }
            }
            if wearables.requiresFirmwareUpdate {
                ActionCard(icon: "arrow.down.circle", title: "Gözlük yazılımı eski", message: "Güncelleme Meta AI'da yapılır.", button: "Güncelle") {
                    Task { await wearables.openFirmwareUpdate() }
                }
            }
            if glasses.needsGlassesAppUpdate {
                ActionCard(icon: "arrow.down.app", title: "Gözlükteki uygulama eski", message: "Güncelleme Meta AI'da yapılır.", button: "Güncelle") {
                    Task { await wearables.openGlassesAppUpdate() }
                }
            }
        }
    }

    // MARK: Start / stop / capture

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if controller.isRunning, controller.state.isActive {
                        await controller.stop()
                    } else {
                        await controller.start()
                    }
                }
            } label: {
                Label(primaryTitle, systemImage: controller.isRunning && controller.state.isActive ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning && controller.state.isActive ? .red : .accentColor)
            .controlSize(.large)

            HStack(spacing: 10) {
                Button {
                    Task { await controller.captureNow() }
                } label: {
                    Label("Şimdi çek", systemImage: "camera.shutter.button").frame(maxWidth: .infinity)
                }
                Button {
                    Task { await controller.requestHighRes() }
                } label: {
                    Label("Yüksek çöz.", systemImage: "camera.aperture").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(controller.state != .running)

            if let notice = controller.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var primaryTitle: String {
        switch controller.state {
        case .paused where controller.isRunning: return "Devam et"
        case _ where controller.isRunning && controller.state.isActive: return "Durdur"
        case .waitingForDevice: return "Durdur"
        default: return "Kaydı başlat"
        }
    }

    private var sourcePickers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kaynak", selection: $config.sourceKind) {
                ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Mod", selection: $config.mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            Text(modeHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(controller.isRunning)
    }

    private var modeHint: String {
        switch config.mode {
        case .adaptive:
            return "Sürekli video yok. Kare; yürüdüğün mesafeye, durup bakmana, dönüşlerine, bulanıklık riskine, pil ve ısıya göre alınır."
        case .stream:
            return "Sürekli akış, \(config.streamFPS) kare/sn. Düşük hız kare başına daha iyi kalite verir; pili en çok bu tüketir."
        case .streamPlusPhoto:
            return "Akış + istek üzerine akış içi fotoğraf (Kişi 2 yazı görünce)."
        case .intervalPhoto:
            return "Akış yok; her \(Int(config.intervalSeconds)) saniyede bir fotoğraf. Pil ölçümünde karşılaştırma için."
        }
    }
}

struct ActionCard: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
