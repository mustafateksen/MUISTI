import SwiftUI

/// Two tabs: the assistant (ask + recording status) and memory. A Siri / Action Button request
/// jumps to "Ask" and listens.
struct RootView: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController
    @State private var tab: AppTab = .assistant
    /// First run: ask once for a natural voice (Ava Premium), see `VoiceSetupSheet`.
    @AppStorage("voiceSetupOffered") private var voiceSetupOffered = false
    @State private var showVoiceSetup = false
    @Environment(\.scenePhase) private var scenePhase
    private var signals: AppSignals { AppSignals.shared }

    var body: some View {
        // `Tab` needs iOS 18; the deployment target is 17.2, so tabs use `tabItem`.
        TabView(selection: $tab) {
            AssistantView(controller: controller, config: config, wearables: wearables)
                .tabItem { Label("Ask", systemImage: "waveform") }
                .tag(AppTab.assistant)
            MemoryListView(controller: controller)
                .tabItem { Label("Memory", systemImage: "square.stack.3d.up") }
                .tag(AppTab.memory)
            SafetyView(safety: controller.safety, ai: controller.ai)
                .tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
                .tag(AppTab.safety)
        }
        // One palette everywhere: toggles, pickers and links follow the brand colour too.
        .tint(.brand)
        .sheet(isPresented: $showVoiceSetup) {
            VoiceSetupSheet { await controller.voice.previewVoice(language: "en") }
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
                case "memory": tab = .memory
                case "safety": tab = .safety
                default: break
                }
            }
            #endif
            handleListenRequest()
            offerVoiceSetup()
        }
        #if DEBUG
        .task { await DebugLaunchArguments.run(controller: controller, config: config, wearables: wearables) }
        #endif
    }

    private func offerVoiceSetup() {
        guard !voiceSetupOffered else { return }
        #if DEBUG
        // Scripted and UI-test launches must not be covered by a sheet.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--") }) { return }
        #endif
        voiceSetupOffered = true
        if !VoicePicker.hasPremiumAva { showVoiceSetup = true }
    }

    private func handleListenRequest() {
        guard signals.consumeListenRequest() else { return }
        tab = .assistant
        Task { await controller.voice.startListening() }
    }
}
