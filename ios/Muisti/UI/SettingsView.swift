import SwiftUI

struct SettingsView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @State private var serverCheck: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sunucu (Kişi 3)") {
                    TextField("http://192.168.1.10:8000", text: $config.serverBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Kareleri /ingest'e gönder", isOn: $config.uploadEnabled)
                    Button("Bağlantıyı dene") { Task { await checkServer() } }
                    if let serverCheck { Text(serverCheck).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Picker("Mod", selection: $config.mode) {
                        ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Akış çözünürlüğü", selection: $config.streamQuality) {
                        ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Akış kare/sn", selection: $config.streamFPS) {
                        ForEach(AppConfig.allowedFPS, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Fotoğraf boyutu", selection: $config.stillResolution) {
                        ForEach(StillResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Fotoğraf kalitesi", selection: $config.stillQuality) {
                        ForEach(StillQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Sabit aralık (C): \(Int(config.intervalSeconds)) sn", value: $config.intervalSeconds, in: 2...60, step: 1)
                    Stepper("Akışta her \(config.passthroughEveryN). kareyi geçir", value: $config.passthroughEveryN, in: 1...30)
                    Toggle("Gözlük gelince yeniden bağlan", isOn: $config.autoReconnect)
                } header: {
                    Text("Yakalama")
                } footer: {
                    Text("Kayıt sürerken değişen yakalama ayarları bir sonraki başlatmada uygulanır.")
                }

                Section {
                    Stepper("En kısa aralık: \(fmt(config.tuning.minInterval)) sn", value: $config.tuning.minInterval, in: 1...15, step: 0.5)
                    Stepper("Dakikada en fazla: \(config.tuning.maxPerMinute)", value: $config.tuning.maxPerMinute, in: 2...40)
                    Stepper("Yürürken her \(fmt(config.tuning.walkingDistance)) m", value: $config.tuning.walkingDistance, in: 3...50, step: 1)
                    Stepper("Yürürken en geç \(fmt(config.tuning.walkingMaxInterval)) sn", value: $config.tuning.walkingMaxInterval, in: 3...60, step: 1)
                    Stepper("Hızlıyken her \(fmt(config.tuning.fastDistance)) m", value: $config.tuning.fastDistance, in: 10...200, step: 5)
                    Stepper("Dönüş eşiği \(fmt(config.tuning.headingChange))°", value: $config.tuning.headingChange, in: 15...120, step: 5)
                    Stepper("Durup bakma \(fmt(config.tuning.dwellSeconds)) sn", value: $config.tuning.dwellSeconds, in: 0.5...6, step: 0.5)
                    Stepper("Dururken yenile \(fmt(config.tuning.stationaryRefresh)) sn", value: $config.tuning.stationaryRefresh, in: 10...300, step: 5)
                    Stepper("Dururken en fazla \(config.tuning.stationaryMaxStills) kare", value: $config.tuning.stationaryMaxStills, in: 0...20)
                    Stepper("Hareket verisi yokken \(fmt(config.tuning.unknownActivityInterval)) sn", value: $config.tuning.unknownActivityInterval, in: 2...60, step: 1)
                    Stepper("Bulanıklık için en çok \(fmt(config.tuning.blurGateMaxWait)) sn bekle", value: $config.tuning.blurGateMaxWait, in: 0...3, step: 0.2)
                    Toggle("Pil/ısı tasarrufu", isOn: $config.tuning.batterySaver)
                    Button("Varsayılana dön") { config.resetTuning() }
                } header: {
                    Text("Uyarlamalı mod")
                } footer: {
                    Text("Düşük pil (telefon < %20 ya da düşük güç modu, gözlük < %20) ve ısı aralıkları uzatır; kritik ısıda çekim durur.")
                }

                Section("Kayıt ve mahremiyet") {
                    Toggle("Kareleri diske kaydet (veri seti)", isOn: $config.recordToDisk)
                    Button("Son 10 dakikayı unut (kuyruk)", role: .destructive) {
                        Task { await controller.forget(minutes: 10) }
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") {
                        Task { await controller.applySettings() }
                        dismiss()
                    }
                }
            }
        }
    }

    private func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func checkServer() async {
        guard let url = config.serverURL else {
            serverCheck = "Adres geçersiz."
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            serverCheck = "Sunucu yanıt verdi (HTTP \(status))."
        } catch {
            serverCheck = "Ulaşılamadı: \(error.localizedDescription)"
        }
    }
}
