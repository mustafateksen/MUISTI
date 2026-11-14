import SwiftUI

/// End-user settings: camera source, AI key, voice, privacy. Everything technical sits behind
/// "Developer options" at the bottom.
struct SettingsView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    let wearables: WearablesController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

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
                                Button(wearables.registrationState == .registering ? "Connecting…" : "Connect", action: register)
                            }
                        }
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    Text(controller.isRunning ? "Stop recording to change the camera." : "Ray-Ban Meta glasses or the iPhone's rear camera.")
                }

                AISettingsSection(controller: controller, config: config)

                Section {
                    LabeledContent("Question language", value: "English")
                    Toggle("Read answers aloud", isOn: $config.speakAnswers)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Hands-free: “Hey Siri, Ask Muisti” or Settings > Action Button > Shortcut > Ask Muisti. The answer plays through the glasses speakers.")
                }

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
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear(perform: applySettings)
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
