import SwiftUI

/// Nemotron API key and a connection test. Endpoint and models are in the developer panel.
struct AISettingsSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @State private var check: ConnectionCheck = .idle

    enum ConnectionCheck: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        Section {
            SecureField("API anahtarı", text: $config.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            Button(action: runCheck) {
                HStack {
                    Text("Bağlantıyı dene")
                    Spacer()
                    checkStatus
                }
            }
            .disabled(check == .checking || config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            if case .failed(let message) = check {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Yapay zekâ")
        } footer: {
            Text("Anahtar Keychain'de saklanır. Telefondan yalnızca bulanıklaştırılmış küçük kare ve okunan yazı gönderilir; hafıza telefonda kalır. Anahtar yoksa arama yerel yapılır.")
        }
        .onChange(of: config.apiKey) { check = .idle }
    }

    @ViewBuilder
    private var checkStatus: some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
        case .ok:
            Label("Çalışıyor", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Başarısız")
        }
    }

    private func runCheck() {
        check = .checking
        Task {
            await controller.applySettings()
            do {
                _ = try await controller.ai.ping()
                check = .ok
            } catch {
                check = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
