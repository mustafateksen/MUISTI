import SwiftUI

/// Stream and photo parameters for the glasses / phone sources.
struct CaptureParametersSection: View {
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Picker("Stream resolution", selection: $config.streamQuality) {
                ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
            }
            Picker("Stream fps", selection: $config.streamFPS) {
                ForEach(AppConfig.allowedFPS, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Photo size", selection: $config.stillResolution) {
                ForEach(StillResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Photo quality", selection: $config.stillQuality) {
                ForEach(StillQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            Stepper("Fixed interval (C): \(Int(config.intervalSeconds)) s", value: $config.intervalSeconds, in: 2...60, step: 1)
            Stepper("Inspect 1 in \(config.passthroughEveryN) stream frames", value: $config.passthroughEveryN, in: 1...30)
            Toggle("Reconnect when glasses return", isOn: $config.autoReconnect)
            Toggle("Keep recording in background", isOn: $config.backgroundCapture)
            Picker("Rotate glasses photo", selection: $config.glassesPhotoRotation) {
                Text("0°").tag(0)
                Text("90° clockwise").tag(90)
                Text("180°").tag(180)
                Text("270° clockwise").tag(270)
            }
        } header: {
            Text("Stream and photo")
        } footer: {
            Text("Capture settings changed while recording apply the next time you start.")
        }
    }
}
