import SwiftUI

/// Provider presets, endpoint and model names.
struct NemotronDeveloperSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Menu("Choose a provider preset") {
                ForEach(NemotronClient.Provider.allCases) { provider in
                    Button(provider.label) { config.use(provider) }
                }
            }
            LabeledContent("Base URL") {
                TextField("https://…/v1", text: $config.apiBaseURL)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Chat model") {
                TextField("model", text: $config.chatModel)
                    .multilineTextAlignment(.trailing)
            }
            Menu("Embedding (semantic search) source") {
                Button("Off: keywords only") { config.embedModel = ""; config.embedBaseURL = "" }
                Button("NVIDIA build (free key)") { config.useNVIDIAEmbeddings() }
                Button("My own Verda container") { config.useOwnEmbeddingContainer(baseURL: config.embedBaseURL) }
            }
            LabeledContent("Embedding model") {
                TextField("empty = keywords only", text: $config.embedModel)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Embedding URL") {
                TextField("empty = same as chat", text: $config.embedBaseURL)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Embedding key") {
                SecureField("empty = same as chat", text: $config.embedKey)
                    .multilineTextAlignment(.trailing)
            }
            Menu("Reranker") {
                Button("Off") { config.rerankModel = "" }
                Button("Nemotron 3.5 Rerank 8B (recommended)") { config.rerankModel = NemotronClient.defaultRerankModel }
                Button("Llama Nemotron Rerank VL 1B (fast)") { config.rerankModel = NemotronClient.fallbackRerankModel }
            }
            LabeledContent("Rerank model") {
                TextField("empty = off", text: $config.rerankModel)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Rerank key") {
                SecureField("empty = embedding key", text: $config.rerankKey)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Nemotron pending", value: "\(controller.pendingCount)")
            LabeledContent("Structured / failed", value: "\(controller.enrichment.enriched) / \(controller.enrichment.failed)")
            if let error = controller.enrichment.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.attention)
            }
        } header: {
            Text("Nemotron 3.5 Super VL")
        } footer: {
            Text("The API key is in the regular Settings. Changes apply when the panel closes.")
        }
        .font(.subheadline)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
