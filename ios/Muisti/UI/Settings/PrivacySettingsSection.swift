import SwiftUI

/// Retention, "forget the last 10 minutes" and no-record zones.
struct PrivacySettingsSection: View {
    let controller: CaptureController
    @Bindable var config: AppConfig
    @State private var confirmForget = false
    @State private var zoneMessage: String?
    @State private var scan = PrivacyScan()

    var body: some View {
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
            if insideZone {
                Label("You're in a no-record zone now", systemImage: "location.slash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.attention)
            }
            ForEach($config.zones) { $zone in
                Picker(selection: $zone.radius) {
                    ForEach(NoRecordZone.radii, id: \.self) { radius in
                        Text(Measurement(value: radius, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                            .tag(radius)
                    }
                } label: {
                    Label(zone.name, systemImage: "mappin.slash")
                }
            }
            .onDelete { config.zones.remove(atOffsets: $0) }
        } header: {
            Text("No-record zones")
        } footer: {
            Text("Nothing seen within the chosen distance of places like home or work is saved to memory; when your position is uncertain, Muisti counts you as inside. Swipe left to delete.")
        }

        Section {
            if scan.running {
                ProgressView(value: Double(scan.checked), total: Double(max(scan.total, 1))) {
                    Text("Checking \(scan.checked) of \(scan.total)…")
                }
                Button("Stop", role: .cancel) { scan.cancel() }
            } else {
                Button("Check saved memories for private places", systemImage: "eye.slash") {
                    scan.start(store: controller.store) { id in await controller.deleteMemory(id) }
                }
                if scan.total > 0 {
                    Text(scan.removed == 0 ? String(localized: "Checked \(scan.checked). Nothing private found.")
                                           : String(localized: "Checked \(scan.checked). Removed \(scan.removed)."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Looks at every saved picture on this iPhone again and deletes those showing a bathroom, a shower or a PIN pad. Nothing is sent anywhere.")
        }
    }

    private var insideZone: Bool {
        guard let fix = controller.location.freshFix(maxAge: 60) else { return false }
        return config.zones.contains { $0.contains(latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.accuracy) }
    }

    private func forgetRecent() {
        Task { await controller.forget(minutes: 10) }
    }

    private func addZone() {
        zoneMessage = controller.addZoneHere(name: String(localized: "Place \(config.zones.count + 1)"))
            ? String(localized: "Added.")
            : String(localized: "Couldn't get your location. Try again while recording.")
    }
}
