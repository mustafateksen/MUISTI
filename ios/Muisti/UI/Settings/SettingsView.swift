import SwiftUI

struct SettingsView: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @State private var serverCheck: String?
    @State private var zoneMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu("Hazır sağlayıcı seç") {
                        ForEach(NemotronClient.Provider.allCases) { provider in
                            Button(provider.label) { config.use(provider) }
                        }
                    }
                    SecureField("API anahtarı", text: $config.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Adres (https://…/v1)", text: $config.apiBaseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                    TextField("Sohbet modeli", text: $config.chatModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                    TextField("Gömme modeli (boş = yalnız anahtar kelime)", text: $config.embedModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                    Button("Bağlantıyı dene") { Task { await checkNemotron() } }
                    if let serverCheck { Text(serverCheck).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Nemotron 3.5 Super VL")
                } footer: {
                    Text("Anahtar Keychain'de saklanır, koda ya da yedeğe girmez. Telefondan yalnızca bulanıklaştırılmış küçük kare ve okunan yazı gönderilir; hafıza telefonda kalır.")
                }

                Section("Ses") {
                    Picker("Soru dili", selection: $config.voiceLocale) {
                        Text("Türkçe").tag("tr-TR")
                        Text("English").tag("en-US")
                        Text("Suomi").tag("fi-FI")
                    }
                    Toggle("Cevabı sesli oku (gözlük hoparlörü)", isOn: $config.speakAnswers)
                    Text("Eller serbest: “Hey Siri, Muisti'ye sor” ya da Ayarlar > Eylem Düğmesi > Kestirme > Muisti'ye sor.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    Stepper("Akışta her \(config.passthroughEveryN). kareyi incele", value: $config.passthroughEveryN, in: 1...30)
                    Toggle("Gözlük gelince yeniden bağlan", isOn: $config.autoReconnect)
                    Picker("Gözlük fotoğrafını döndür", selection: $config.glassesPhotoRotation) {
                        Text("0°").tag(0)
                        Text("90° saat yönü").tag(90)
                        Text("180°").tag(180)
                        Text("270° saat yönü").tag(270)
                    }
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

                Section {
                    Stepper("Kayıtları \(config.retentionDays) gün sakla", value: $config.retentionDays, in: 1...30)
                    Button("Son 10 dakikayı unut", role: .destructive) {
                        Task { await controller.forget(minutes: 10) }
                    }
                    Button("Bulunduğum yeri kayıt dışı yap (100 m)") {
                        zoneMessage = controller.addZoneHere(name: "Bölge \(config.zones.count + 1)")
                            ? "Eklendi." : "Konum yok; kayıt sırasında tekrar dene."
                    }
                    if let zoneMessage { Text(zoneMessage).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(config.zones) { zone in
                        HStack {
                            Text(zone.name)
                            Spacer()
                            Text(String(format: "%.4f, %.4f", zone.latitude, zone.longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { config.zones.remove(atOffsets: $0) }
                    Toggle("Ham kareleri de kaydet (yalnızca veri seti)", isOn: $config.recordToDisk)
                } header: {
                    Text("Mahremiyet")
                } footer: {
                    Text("Yüzler ve plakalar telefonda bulanıklaştırılır; ham kare saklanmaz (veri seti anahtarı kapalıyken). Kayıt dışı bölgelerde kare alınsa bile hafızaya yazılmaz.")
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

    private func checkNemotron() async {
        serverCheck = "Deneniyor…"
        await controller.applySettings()
        do {
            let reply = try await controller.ai.ping()
            serverCheck = "Nemotron yanıt verdi: \(reply.prefix(20))"
        } catch {
            serverCheck = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
