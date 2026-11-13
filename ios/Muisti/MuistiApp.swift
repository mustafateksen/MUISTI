import MWDATCore
import SwiftUI

@main
struct MuistiApp: App {
    @State private var config: AppConfig
    @State private var wearables: WearablesController
    @State private var controller: CaptureController

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[Muisti] Wearables.configure failed: \(error)")
        }
        let config = AppConfig()
        let wearables = WearablesController()
        _config = State(wrappedValue: config)
        _wearables = State(wrappedValue: wearables)
        _controller = State(wrappedValue: CaptureController(config: config, wearables: wearables))
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, config: config, wearables: wearables)
                .onOpenURL { url in
                    // Only Meta AI callbacks go to the SDK.
                    guard
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                        components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else { return }
                    Task { await wearables.handleOpenURL(url) }
                }
        }
    }
}

/// Three tabs: capture, ask, memory. A Siri / Action Button request jumps to "Sor" and listens.
struct RootView: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase
    private var signals: AppSignals { AppSignals.shared }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(controller: controller, config: config, wearables: wearables)
                .tabItem { Label("Kayıt", systemImage: "eyeglasses") }
                .tag(0)
            AskView(controller: controller, voice: controller.voice)
                .tabItem { Label("Sor", systemImage: "mic.fill") }
                .tag(1)
            MemoryListView(controller: controller)
                .tabItem { Label("Hafıza", systemImage: "square.stack.3d.up") }
                .badge(controller.memoryCount)
                .tag(2)
        }
        .onChange(of: signals.pendingListen) { _, pending in
            if pending { handleListenRequest() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { handleListenRequest() }
        }
        .task { handleListenRequest() }
    }

    private func handleListenRequest() {
        guard signals.consumeListenRequest() else { return }
        tab = 1
        Task { await controller.voice.startListening() }
    }
}
