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
            SecureField("API key", text: $config.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            Button(action: runCheck) {
                HStack {
                    Text("Test connection")
                    Spacer()
                    checkStatus
                }
            }
            .disabled(check == .checking || config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            if case .failed(let message) = check {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.danger)
            }
        } header: {
            Text("AI")
        } footer: {
            Text("The key is stored in the Keychain. Only a small blurred frame and the text read from it leave your iPhone; your memory stays on the device. Without a key, search runs locally.")
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
            Label("Working", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.danger)
                .accessibilityLabel("Failed")
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
