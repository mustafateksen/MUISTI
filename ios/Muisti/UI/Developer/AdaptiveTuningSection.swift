import SwiftUI

/// Thresholds for the adaptive scheduler (see `AdaptiveScheduler`).
struct AdaptiveTuningSection: View {
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Stepper("Min interval: \(fmt(config.tuning.minInterval)) s", value: $config.tuning.minInterval, in: 1...15, step: 0.5)
            Stepper("Max per minute: \(config.tuning.maxPerMinute)", value: $config.tuning.maxPerMinute, in: 2...40)
            Stepper("Walking: every \(fmt(config.tuning.walkingDistance)) m", value: $config.tuning.walkingDistance, in: 3...50, step: 1)
            Stepper("Walking: at most every \(fmt(config.tuning.walkingMaxInterval)) s", value: $config.tuning.walkingMaxInterval, in: 3...60, step: 1)
            Stepper("Fast: every \(fmt(config.tuning.fastDistance)) m", value: $config.tuning.fastDistance, in: 10...200, step: 5)
            Stepper("Turn threshold \(fmt(config.tuning.headingChange))°", value: $config.tuning.headingChange, in: 15...120, step: 5)
            Stepper("Dwell \(fmt(config.tuning.dwellSeconds)) s", value: $config.tuning.dwellSeconds, in: 0.5...6, step: 0.5)
            Stepper("Stationary refresh \(fmt(config.tuning.stationaryRefresh)) s", value: $config.tuning.stationaryRefresh, in: 10...300, step: 5)
            Stepper("Stationary max \(config.tuning.stationaryMaxStills) frames", value: $config.tuning.stationaryMaxStills, in: 0...20)
            Stepper("No motion data: \(fmt(config.tuning.unknownActivityInterval)) s", value: $config.tuning.unknownActivityInterval, in: 2...60, step: 1)
            Stepper("Wait up to \(fmt(config.tuning.blurGateMaxWait)) s for sharpness", value: $config.tuning.blurGateMaxWait, in: 0...3, step: 0.2)
            Toggle("Battery/thermal saver", isOn: $config.tuning.batterySaver)
            Button("Reset to defaults", role: .destructive, action: config.resetTuning)
        } header: {
            Text("Adaptive mode")
        } footer: {
            Text("Low battery (iPhone < 20% or Low Power Mode, glasses < 20%) and heat lengthen the intervals; capture stops at critical temperature.")
        }
    }

    private func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
