import MapKit
import SwiftUI

/// One memory: the blurred keyframe, quick actions (call, map), what was read, when and where.
struct MemoryDetailView: View {
    let record: MemoryRecord
    let controller: CaptureController
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var episode: MemoryEpisode?

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = record.latitude, let lon = record.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                KeyframeImage(url: controller.store.frameURL(record), maxPixel: 1280, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                    .opensPhotoViewer(url: controller.store.frameURL(record), title: record.name ?? record.title)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if let kind = record.kind, record.name != nil {
                        Text(kind.uppercased())
                            .font(.footnote.bold())
                            .foregroundStyle(.tint)
                    }
                    Text(record.name ?? record.title)
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Label(record.seenAt.formatted(date: .complete, time: .shortened), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let street = record.street {
                        Label(street, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // Named place / district / city / floor, when it adds something to the street.
                    if let area = record.area, !area.isEmpty, area != record.street {
                        Label(area, systemImage: "building.2")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                MemoryQuickActions(record: record, coordinate: coordinate)

                MemoryFactsCard(record: record, showsTechnical: developerMode)

                if let episode {
                    NavigationLink(value: episode) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Episode for this memory").font(.footnote).foregroundStyle(.secondary)
                                Text(episode.displayTitle).font(.body).lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .card()
                }

                if let visual = record.visual {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Label("Visual details", systemImage: "eye")
                            .font(.headline)
                        ForEach(Array(visual.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .card()
                }

                // The raw OCR text is noisy; keep it one tap away instead of on the page.
                if !record.ocrText.isEmpty {
                    DisclosureGroup {
                        Text(record.ocrText)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Spacing.s)
                    } label: {
                        Label("Text in the frame", systemImage: "text.viewfinder")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .card()
                }

                if let coordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500))) {
                        Marker(record.title, coordinate: coordinate)
                    }
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                }

                Button("Delete this memory", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive, action: delete)
                    }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: record.episodeID) {
            if let id = record.episodeID { episode = await controller.store.episode(id: id) }
        }
    }

    private func delete() {
        Task {
            await controller.deleteMemory(record.id)
            dismiss()
        }
    }
}
