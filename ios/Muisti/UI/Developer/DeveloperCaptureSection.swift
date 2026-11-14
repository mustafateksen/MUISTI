import SwiftUI

/// Capture mode (adaptive / A / B / C) and the manual capture triggers.
struct DeveloperCaptureSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Picker("Mode", selection: $config.mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(controller.isRunning)
            Text(modeHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Capture now", systemImage: "camera.shutter.button", action: captureNow)
                .disabled(controller.state != .running)
            Button("High-resolution photo", systemImage: "camera.aperture", action: requestHighRes)
                .disabled(controller.state != .running)
        } header: {
            Text("Capture mode")
        } footer: {
            if controller.isRunning {
                Text("Stop recording to change the mode.")
            }
        }
    }

    private var modeHint: String {
        switch config.mode {
        case .adaptive:
            return "No continuous video. Frames are taken based on distance walked, pausing to look, turns, blur risk, battery and heat."
        case .stream:
            return "Continuous stream, \(config.streamFPS) fps. Lower frame rates give better quality per frame; uses the most battery."
        case .streamPlusPhoto:
            return "Stream + in-stream photo on request (when Person 2 spots text)."
        case .intervalPhoto:
            return "No stream; one photo every \(Int(config.intervalSeconds)) seconds. For battery-measurement comparison."
        }
    }

    private func captureNow() {
        Task { await controller.captureNow() }
    }

    private func requestHighRes() {
        Task { await controller.requestHighRes() }
    }
}
