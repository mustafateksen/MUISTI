import SwiftUI

/// The main screen, chatbot style. Voice mode (the orb, live captions) fills the screen while
/// Muisti listens or thinks, and on an empty chat. Once an answer arrives the conversation
/// shows it right away; while it is read aloud the orb sits small where the composer was.
/// Glasses / recording status is an island in the top-left corner.
struct AssistantView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController

    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @State private var typed = ""
    @FocusState private var typing: Bool
    @State private var showPanel = false
    @State private var showSettings = false
    @State private var showDeveloper = false
    @State private var confirmPermission = false
    /// A typed question waiting for its answer: it stays in the chat with a typing indicator
    /// (no jump to the full-screen orb in the middle of a conversation).
    @State private var pendingTyped: String?

    private var voice: VoiceAssistant { controller.voice }
    private var voiceMode: Bool {
        if pendingTyped != nil { return false }
        return voice.phase == .listening || voice.phase == .thinking || voice.history.isEmpty
    }

    var body: some View {
        ZStack {
            if voiceMode {
                VoiceStage(
                    voice: voice,
                    showsSuggestions: voice.history.isEmpty,
                    onOrbTap: orbTapped,
                    onSuggestion: ask
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                transcript
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.smooth(duration: 0.45), value: voiceMode)
        .background { AskBackdrop(phase: voice.phase, voiceMode: voiceMode) }
        .safeAreaInset(edge: .top, spacing: 0) {
            AssistantTopBar(
                status: IslandStatus(controller: controller, config: config, wearables: wearables),
                canClear: !voice.history.isEmpty && !voice.isBusy,
                developerMode: developerMode,
                fades: !voiceMode,
                perform: perform,
                showDetails: { showPanel = true },
                clear: voice.clearConversation,
                showDeveloper: { showDeveloper = true },
                showSettings: { showSettings = true }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if voice.phase == .speaking {
                    SpeakingBar(voice: voice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if pendingTyped != nil {
                    ChatComposer(text: $typed, focus: $typing, isBusy: true, onSend: send, onVoice: {})
                } else if voice.isBusy {
                    VoiceControls(phase: voice.phase, onCancel: voice.cancel)
                } else {
                    ChatComposer(text: $typed, focus: $typing, isBusy: voice.isBusy, onSend: send, onVoice: startVoice)
                }
            }
            .animation(Theme.Motion.standard, value: voice.isBusy)
        }
        .sensoryFeedback(.success, trigger: voice.lastResult?.id)
        .sheet(isPresented: $showPanel) {
            CapturePanel(controller: controller, config: config, wearables: wearables)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(controller: controller, config: config, wearables: wearables)
        }
        .sheet(isPresented: $showDeveloper) {
            NavigationStack {
                DeveloperView(controller: controller, config: config, wearables: wearables, showsDoneButton: true)
            }
        }
        .glassesPermissionAlert(isPresented: $confirmPermission, controller: controller, config: config, wearables: wearables)
        .onChange(of: wearables.registrationState) { _, newState in
            // Back from Meta AI: continue where the user left off.
            guard newState == .registered, controller.isRunning, controller.state == .needsRegistration else { return }
            Task { await controller.start() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatTranscript(voice: voice, store: controller.store, pending: pendingTyped)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: pendingTyped) { _, pending in
                if pending != nil { withAnimation(Theme.Motion.standard) { proxy.scrollTo("pending", anchor: .bottom) } }
            }
            .onChange(of: voice.history.first?.id) { _, id in
                // The answer arrived: show it from its question.
                if let id { withAnimation(Theme.Motion.standard) { proxy.scrollTo(id, anchor: .top) } }
            }
            .onAppear {
                // Back from voice mode: start the newest answer at its question.
                if let id = voice.history.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    // MARK: Actions

    private func perform(_ action: IslandAction) {
        switch action {
        case .start, .resume, .retry:
            Task { await controller.start() }
        case .stop:
            Task { await controller.stop() }
        case .register:
            Task { await wearables.register() }
        case .permission:
            confirmPermission = true
        }
    }

    private func orbTapped() {
        if voice.phase == .speaking {
            voice.cancel()
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        typing = false
        Task { await voice.toggleListening() }
    }

    private func ask(_ question: String) {
        Task { await voice.ask(question) }
    }

    private func send() {
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !voice.isBusy else { return }
        typed = ""
        typing = false
        pendingTyped = question
        Task {
            await voice.ask(question)
            pendingTyped = nil
        }
    }
}
