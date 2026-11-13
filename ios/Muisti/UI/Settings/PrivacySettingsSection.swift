import SwiftUI

/// Retention, "forget the last 10 minutes" and no-record zones.
struct PrivacySettingsSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @State private var confirmForget = false
    @State private var zoneMessage: String?

    var body: some View {
        Section {
            Stepper("Kayıtları \(config.retentionDays) gün sakla", value: $config.retentionDays, in: 1...30)
            Button("Son 10 dakikayı unut", systemImage: "clock.arrow.circlepath", role: .destructive) {
                confirmForget = true
            }
            .confirmationDialog("Son 10 dakikadaki kayıtlar silinsin mi?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Unut", role: .destructive, action: forgetRecent)
            }
        } header: {
            Text("Mahremiyet")
        } footer: {
            Text("Yüzler ve plakalar telefonda bulanıklaştırılır; ham video saklanmaz.")
        }

        Section {
            Button("Bulunduğum yeri kayıt dışı yap", systemImage: "location.slash.circle", action: addZone)
            if let zoneMessage {
                Text(zoneMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(config.zones) { zone in
                Label(zone.name, systemImage: "mappin.slash")
            }
            .onDelete { config.zones.remove(atOffsets: $0) }
        } header: {
            Text("Kayıt dışı yerler")
        } footer: {
            Text("Ev ya da iş gibi yerlerin 100 m çevresinde görülenler hafızaya yazılmaz. Silmek için sola kaydır.")
        }
    }

    private func forgetRecent() {
        Task { await controller.forget(minutes: 10) }
    }

    private func addZone() {
        zoneMessage = controller.addZoneHere(name: "Yer \(config.zones.count + 1)")
            ? "Eklendi."
            : "Konum alınamadı. Kayıt sürerken tekrar dene."
    }
}
