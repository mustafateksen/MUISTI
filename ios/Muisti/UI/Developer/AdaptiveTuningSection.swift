import SwiftUI

/// Thresholds for the adaptive scheduler (see `AdaptiveScheduler`).
struct AdaptiveTuningSection: View {
    @Bindable var config: AppConfig

    var body: some View {
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
            Button("Varsayılana dön", role: .destructive, action: config.resetTuning)
        } header: {
            Text("Uyarlamalı mod")
        } footer: {
            Text("Düşük pil (telefon < %20 ya da düşük güç modu, gözlük < %20) ve ısı aralıkları uzatır; kritik ısıda çekim durur.")
        }
    }

    private func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
