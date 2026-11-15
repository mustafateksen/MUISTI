import AVFoundation
import SwiftUI

/// End-user settings: camera source, AI key, voice, privacy. Everything technical sits behind
/// "Developer options" at the bottom.
struct SettingsView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @State private var showVoiceSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Camera", selection: $config.sourceKind) {
                        ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(controller.isRunning)
                    if config.sourceKind == .glasses {
                        LabeledContent("Glasses") {
                            if wearables.isRegistered {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.success)
                            } else {
                                Button(wearables.registrationState == .registering ? String(localized: "Connecting…") : String(localized: "Connect"), action: register)
                            }
                        }
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    Text(controller.isRunning ? String(localized: "Stop recording to change the camera.") : String(localized: "Ray-Ban Meta glasses or the iPhone's rear camera."))
                }

                AISettingsSection(controller: controller, config: config)

                Section {
                    Picker("Question language", selection: $config.speechLanguage) {
                        Text("Automatic").tag(SpeechLanguage.automatic)
                        ForEach(SpeechLanguage.choices, id: \.id) { choice in
                            Text(verbatim: choice.name).tag(choice.id)
                        }
                    }
                    .onChange(of: config.speechLanguage) { applySettings() }
                    NavigationLink(value: SettingsRoute.micTest) {
                        Label("Microphone test and speech engine", systemImage: "waveform.and.mic")
                    }
                    Toggle("Read answers aloud", isOn: $config.speakAnswers)
                    if config.speakAnswers, !VoicePicker.hasPremiumAva {
                        Button("Get a natural voice (Ava)", systemImage: "waveform.badge.plus") { showVoiceSetup = true }
                    }
                    if config.speakAnswers {
                        AnswerVoicePicker(controller: controller, language: "en", title: String(localized: "English voice"))
                        AnswerVoicePicker(controller: controller, language: "tr", title: String(localized: "Turkish voice"))
                        AnswerVoicePicker(controller: controller, language: "fi", title: String(localized: "Finnish voice"))
                    }
                    Toggle("Ask through the glasses", isOn: $config.handsFree)
                    if config.handsFree {
                        LabeledContent("Wake word") {
                            TextField("Muisti", text: $config.wakeWord)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        WakeWordTeacher(controller: controller, config: config)
                        if wearables.microphonePermission != .granted {
                            Button("Allow the glasses microphone") {
                                Task {
                                    if await wearables.requestMicrophonePermission() { await controller.applySettings() }
                                }
                            }
                        } else {
                            Label("Glasses microphone allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.success)
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("While recording, say the wake word and your question to the glasses (“Muisti, where was the Arduino stand?”). The glasses turn speech into text themselves; the answer plays through their speakers. Or: “Hey Siri, Ask Muisti”.")
                }

                Section {
                    Toggle("Notice hazards by itself", isOn: $config.safetyAuto)
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Muisti looks for things like a stove, iron or candle left on, smoke or running water, and warns you when you leave or forget them. Your own rules (Safety tab) work either way.")
                }

                AgentSettingsSection(controller: controller)

                PrivacySettingsSection(controller: controller, config: config)

                Section {
                    Toggle("Developer options", isOn: $developerMode.animation())
                    if developerMode {
                        NavigationLink(value: SettingsRoute.developer) {
                            Label("Developer panel", systemImage: "hammer")
                        }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Capture modes, Nemotron server, scheduler tuning and live diagnostics. When on, a button also appears on the Recording screen.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionText)
                } footer: {
                    Text("Muisti remembers what you see. Your memory stays on this iPhone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .developer:
                    DeveloperView(controller: controller, config: config, wearables: wearables)
                case .assistantNotes:
                    AgentNotesView(controller: controller)
                case .micTest:
                    MicTestView(controller: controller)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear(perform: applySettings)
            .sheet(isPresented: $showVoiceSetup) {
                VoiceSetupSheet { await controller.voice.previewVoice(language: "en") }
            }
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func register() {
        Task { await wearables.register() }
    }

    private func applySettings() {
        Task { await controller.applySettings() }
    }
}

/// The voice answers are read in, per language: by default the iPhone's own Spoken Content
/// voice (Accessibility settings), or one picked here.
/// If only basic (robotic) voices are installed, says where to get a natural one; downloading it
/// is a system setting apps cannot do.
private struct AnswerVoicePicker: View {
    let controller: CaptureController
    let language: String
    let title: String
    @State private var selection: String = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        Group {
            Picker(title, selection: $selection) {
                Text(autoLabel).tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) · \(VoicePicker.qualityLabel(voice))").tag(voice.identifier)
                }
            }
            .onChange(of: selection) { _, id in
                VoicePicker.choose(voices.first { $0.identifier == id }, for: language)
            }
            Button("Play \(title.lowercased())", systemImage: "play.circle") {
                Task { await controller.voice.previewVoice(language: language) }
            }
            if !VoicePicker.hasNaturalVoice(for: language) {
                Text("Only a basic voice is installed. For a natural one, download a Premium or Enhanced voice in Settings › Accessibility › Spoken Content › Voices, then come back here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            voices = VoicePicker.voices(for: language)
            selection = VoicePicker.chosenID(for: language) ?? ""
        }
    }

    private var autoLabel: String {
        if let best = VoicePicker.naturalVoice(for: language) {
            return String(localized: "Automatic (\(best.name), best installed)")
        }
        return String(localized: "Same as iPhone (Spoken Content)")
    }
}

/// Teaches the wake word: the user says it three times through the glasses; the spellings the
/// glasses' recogniser produces ("music" for "Muisti") then also wake Muisti.
private struct WakeWordTeacher: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @State private var listening = false
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(listening ? String(localized: "Say “\(config.wakeWord)” 3 times…") : String(localized: "Teach the wake word")) {
                let speech = controller.glasses.headSpeech
                guard controller.isRunning, controller.config.sourceKind == .glasses else {
                    hint = String(localized: "Put on the glasses and wait until recording starts, then try again.")
                    return
                }
                hint = nil
                listening = true
                speech.learnWakeWord { spellings in
                    listening = false
                    config.wakeAliases = spellings
                    Task { await controller.applySettings() }
                }
            }
            .disabled(listening)
            if listening {
                let speech = controller.glasses.headSpeech
                Text("Heard \(speech.learning?.count ?? 0)/3 · “\(speech.lastHeard)”")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.attention)
            }
            if !config.wakeAliases.isEmpty {
                Text("The glasses hear it as: \(config.wakeAliases.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
