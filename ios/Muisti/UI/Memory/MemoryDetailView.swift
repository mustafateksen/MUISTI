import MapKit
import SwiftUI

/// One memory: the blurred keyframe, quick actions (call, map), what was read, when and where.
struct MemoryDetailView: View {
    let record: MemoryRecord
    let controller: CaptureController
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = record.latitude, let lon = record.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                KeyframeImage(url: controller.store.frameURL(record), maxPixel: 1280)
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if let kind = record.kind, record.name != nil {
                        Text(kind.uppercased())
                            .font(.footnote.bold())
                            .foregroundStyle(.tint)
                    }
                    Text(record.name ?? record.title)
                        .font(.title.bold())
                    Label(record.seenAt.formatted(date: .complete, time: .shortened), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let street = record.street {
                        Label(street, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                MemoryQuickActions(record: record, coordinate: coordinate)

                MemoryFactsCard(record: record, showsTechnical: developerMode)

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("Karede okunan yazı", systemImage: "text.viewfinder")
                        .font(.headline)
                    Text(record.ocrText.isEmpty ? "Yazı okunmadı." : record.ocrText)
                        .font(.callout.monospaced())
                        .foregroundStyle(record.ocrText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                .card()

                if let coordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500))) {
                        Marker(record.title, coordinate: coordinate)
                    }
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                }

                Button("Bu anıyı sil", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog("Bu anı silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Sil", role: .destructive, action: delete)
                    }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func delete() {
        Task {
            await controller.deleteMemory(record.id)
            dismiss()
        }
    }
}
