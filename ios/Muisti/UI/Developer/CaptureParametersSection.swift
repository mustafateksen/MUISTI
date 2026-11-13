import SwiftUI

/// Stream and photo parameters for the glasses / phone sources.
struct CaptureParametersSection: View {
    @Bindable var config: AppConfig

    var body: some View {
        Section {
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
            Text("Akış ve fotoğraf")
        } footer: {
            Text("Kayıt sürerken değişen yakalama ayarları bir sonraki başlatmada uygulanır.")
        }
    }
}
