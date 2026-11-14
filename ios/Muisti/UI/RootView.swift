import SwiftUI

/// Two tabs: the assistant (ask + recording status) and memory. A Siri / Action Button request
/// jumps to "Ask" and listens.
struct RootView: View {
    let controller: CaptureController
    let config: AppConfig
    let wearables: WearablesController
    @State private var tab: AppTab = .assistant
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
        }
        .alert("Remember your peanut allergy?", isPresented: Binding(get: { controller.voice.confirmPeanut },
            set: { controller.voice.confirmPeanut = $0 })) {
            Button("Remember and alert") { controller.voice.setPeanut(true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("During capture, Muisti can warn you about peanut wording it can read. Change this in Privacy.")
        }
        .safeAreaInset(edge: .top) {
            if let alert = controller.voice.labelEvidence {
                VStack(alignment: .leading) {
                    Text(alert.reading.message).bold()
                    Text(alert.quotes.joined(separator: " · "))
                    HStack {
                        Text(alert.at, style: .time)
                        Text("OCR: " + alert.lineNumbers.map { String($0) }.joined(separator: ", "))
                        Spacer()
                        Button("Dismiss") { controller.voice.dismissLabel() }
                    }.font(.caption)
                }.padding(8).background(.regularMaterial)
            }
        }
        // One palette everywhere: toggles, pickers and links follow the brand colour too.
        .tint(.brand)
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
        tab = .assistant
        Task { await controller.voice.startListening() }
    }
}
