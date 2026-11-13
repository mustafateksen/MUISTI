import SwiftUI

/// Three tabs: capture, ask, memory. A Siri / Action Button request jumps to "Sor" and listens.
struct RootView: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController
    @State private var tab: AppTab = .capture
    @Environment(\.scenePhase) private var scenePhase
    private var signals: AppSignals { AppSignals.shared }

    var body: some View {
        // `Tab` needs iOS 18; the deployment target is 17.2, so tabs use `tabItem`.
        TabView(selection: $tab) {
            HomeView(controller: controller, config: config, wearables: wearables)
                .tabItem { Label("Kayıt", systemImage: "eyeglasses") }
                .tag(AppTab.capture)
            AskView(controller: controller, voice: controller.voice)
                .tabItem { Label("Sor", systemImage: "waveform") }
                .tag(AppTab.ask)
            MemoryListView(controller: controller)
                .tabItem { Label("Hafıza", systemImage: "square.stack.3d.up") }
                .tag(AppTab.memory)
        }
        .onChange(of: signals.pendingListen) { _, pending in
            if pending { handleListenRequest() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { handleListenRequest() }
        }
        .task {
            #if DEBUG
            // `--tab=ask|memory`: open on a tab (screenshots, UI checks).
            if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tab=") }) {
                switch arg.dropFirst(6) {
                case "ask": tab = .ask
                case "memory": tab = .memory
                default: break
                }
            }
            #endif
            handleListenRequest()
        }
        #if DEBUG
        .task { await DebugLaunchArguments.run(controller: controller, config: config, wearables: wearables) }
        #endif
    }

    private func handleListenRequest() {
        guard signals.consumeListenRequest() else { return }
        tab = .ask
        Task { await controller.voice.startListening() }
    }
}
