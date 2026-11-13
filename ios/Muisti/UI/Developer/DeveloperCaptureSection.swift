import SwiftUI

/// Capture mode (adaptive / A / B / C) and the manual capture triggers.
struct DeveloperCaptureSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig

    var body: some View {
        Section {
            Picker("Mod", selection: $config.mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(controller.isRunning)
            Text(modeHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Şimdi çek", systemImage: "camera.shutter.button", action: captureNow)
                .disabled(controller.state != .running)
            Button("Yüksek çözünürlüklü fotoğraf", systemImage: "camera.aperture", action: requestHighRes)
                .disabled(controller.state != .running)
        } header: {
            Text("Yakalama modu")
        } footer: {
            if controller.isRunning {
                Text("Modu değiştirmek için kaydı durdur.")
            }
        }
    }

    private var modeHint: String {
        switch config.mode {
        case .adaptive:
            return "Sürekli video yok. Kare; yürüdüğün mesafeye, durup bakmana, dönüşlerine, bulanıklık riskine, pil ve ısıya göre alınır."
        case .stream:
            return "Sürekli akış, \(config.streamFPS) kare/sn. Düşük hız kare başına daha iyi kalite verir; pili en çok bu tüketir."
        case .streamPlusPhoto:
            return "Akış + istek üzerine akış içi fotoğraf (Kişi 2 yazı görünce)."
        case .intervalPhoto:
            return "Akış yok; her \(Int(config.intervalSeconds)) saniyede bir fotoğraf. Pil ölçümünde karşılaştırma için."
        }
    }

    private func captureNow() {
        Task { await controller.captureNow() }
    }

    private func requestHighRes() {
        Task { await controller.requestHighRes() }
    }
}
