import SwiftUI

/// Retention, "forget the last 10 minutes" and no-record zones.
struct PrivacySettingsSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @State private var confirmForget = false
    @State private var zoneMessage: String?

    var body: some View {
        Section {
            Toggle("Peanut label alerts", isOn: Binding(get: { controller.voice.peanutEnabled },
                set: { controller.voice.setPeanut($0) }))
        } footer: {
            Text("Checks readable English, Finnish and Swedish peanut wording during capture. Silence does not confirm a product is safe.")
        }

        Section {
            Stepper("Keep memories for \(config.retentionDays) days", value: $config.retentionDays, in: 1...30)
            Button("Forget the last 10 minutes", systemImage: "clock.arrow.circlepath", role: .destructive) {
                confirmForget = true
            }
            .confirmationDialog("Delete memories from the last 10 minutes?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive, action: forgetRecent)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Faces and license plates are blurred on your iPhone; raw video is never stored.")
        }

        Section {
            Button("Don't record at my current location", systemImage: "location.slash.circle", action: addZone)
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
            Text("No-record zones")
        } footer: {
            Text("Nothing seen within 100 m of places like home or work is saved to memory. Swipe left to delete.")
        }
    }

    private func forgetRecent() {
        Task { await controller.forget(minutes: 10) }
    }

    private func addZone() {
        zoneMessage = controller.addZoneHere(name: "Place \(config.zones.count + 1)")
            ? "Added."
            : "Couldn't get your location. Try again while recording."
    }
}
