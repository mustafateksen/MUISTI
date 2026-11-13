import SwiftUI

/// Provider presets, endpoint and model names.
struct NemotronDeveloperSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Menu("Hazır sağlayıcı seç") {
                ForEach(NemotronClient.Provider.allCases) { provider in
                    Button(provider.label) { config.use(provider) }
                }
            }
            LabeledContent("Adres") {
                TextField("https://…/v1", text: $config.apiBaseURL)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Sohbet modeli") {
                TextField("model", text: $config.chatModel)
                    .multilineTextAlignment(.trailing)
            }
            Menu("Gömme (anlam araması) kaynağı") {
                Button("Kapalı: yalnız anahtar kelime") { config.embedModel = ""; config.embedBaseURL = "" }
                Button("NVIDIA build (ücretsiz anahtar)") { config.useNVIDIAEmbeddings() }
                Button("Kendi Verda konteynerim") { config.useOwnEmbeddingContainer(baseURL: config.embedBaseURL) }
            }
            LabeledContent("Gömme modeli") {
                TextField("boş = yalnız anahtar kelime", text: $config.embedModel)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Gömme adresi") {
                TextField("boş = sohbetle aynı", text: $config.embedBaseURL)
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Gömme anahtarı") {
                SecureField("boş = sohbetle aynı", text: $config.embedKey)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Nemotron bekleyen", value: "\(controller.pendingCount)")
            LabeledContent("Yapılandırılan / başarısız", value: "\(controller.enrichment.enriched) / \(controller.enrichment.failed)")
            if let error = controller.enrichment.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Nemotron 3.5 Super VL")
        } footer: {
            Text("API anahtarı son kullanıcı Ayarlar'ında. Değişiklikler panel kapanınca uygulanır.")
        }
        .font(.subheadline)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
