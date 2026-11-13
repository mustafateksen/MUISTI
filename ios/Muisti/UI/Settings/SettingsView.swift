import SwiftUI

/// End-user settings: camera source, AI key, voice, privacy. Everything technical sits behind
/// "Geliştirici seçenekleri" at the bottom.
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
                    Picker("Kamera", selection: $config.sourceKind) {
                        ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(controller.isRunning)
                    if config.sourceKind == .glasses {
                        LabeledContent("Gözlük") {
                            if wearables.isRegistered {
                                Label("Bağlı", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button(wearables.registrationState == .registering ? "Bağlanıyor…" : "Bağlan", action: register)
                            }
                        }
                    }
                } header: {
                    Text("Kamera")
                } footer: {
                    Text(controller.isRunning ? "Kamerayı değiştirmek için önce kaydı durdur." : "Ray-Ban Meta gözlük ya da telefonun arka kamerası.")
                }

                AISettingsSection(controller: controller, config: config)

                Section {
                    Picker("Soru dili", selection: $config.voiceLocale) {
                        Text("Türkçe").tag("tr-TR")
                        Text("English").tag("en-US")
                        Text("Suomi").tag("fi-FI")
                    }
                    Toggle("Cevabı sesli oku", isOn: $config.speakAnswers)
                } header: {
                    Text("Ses")
                } footer: {
                    Text("Eller serbest: “Hey Siri, Muisti'ye sor” ya da Ayarlar > Eylem Düğmesi > Kestirme > Muisti'ye sor. Cevap gözlük hoparlöründen okunur.")
                }

                PrivacySettingsSection(controller: controller, config: config)

                Section {
                    Toggle("Geliştirici seçenekleri", isOn: $developerMode.animation())
                    if developerMode {
                        NavigationLink(value: SettingsRoute.developer) {
                            Label("Geliştirici paneli", systemImage: "hammer")
                        }
                    }
                } header: {
                    Text("Gelişmiş")
                } footer: {
                    Text("Yakalama modları, Nemotron sunucusu, zamanlayıcı ayarları ve canlı tanılama. Açıkken Kayıt ekranında da bir düğme görünür.")
                }

                Section {
                    LabeledContent("Sürüm", value: Self.versionText)
                } footer: {
                    Text("Muisti gördüklerini senin için hatırlar. Hafıza bu telefonda kalır.")
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .developer:
                    DeveloperView(controller: controller, config: config, wearables: wearables)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
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
