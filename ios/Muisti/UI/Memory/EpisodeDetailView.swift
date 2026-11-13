import MapKit
import SwiftUI

/// One memory episode: what happened (Nemotron's summary), the route on a map and every frame
/// in the order it was seen.
struct EpisodeDetailView: View {
    let episode: MemoryEpisode
    let controller: CaptureController
    @State private var frames: [MemoryRecord] = []

    private var located: [MemoryRecord] { frames.filter { $0.latitude != nil && $0.longitude != nil } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(episode.displayTitle)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Label(timeSpan, systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let street = episode.street {
                        Label(street, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Spacing.xxs)
                    } else {
                        Label("Özet birazdan hazır olur.", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            if !located.isEmpty {
                Section {
                    Map(initialPosition: .automatic) {
                        ForEach(located) { record in
                            Marker(record.title, coordinate: CLLocationCoordinate2D(latitude: record.latitude!, longitude: record.longitude!))
                        }
                        if located.count > 1 {
                            MapPolyline(coordinates: located.map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) })
                                .stroke(.tint, lineWidth: 3)
                        }
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section("Kareler (\(frames.count))") {
                ForEach(frames) { record in
                    NavigationLink(value: record) {
                        MemoryRow(record: record, store: controller.store)
                    }
                    .accessibilityIdentifier("frameRow")
                }
            }
        }
        .navigationTitle(episode.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: controller.memoryRevision) {
            frames = await controller.store.records(inEpisode: episode.id)
        }
    }

    private var timeSpan: String {
        let day = episode.startedAt.formatted(date: .abbreviated, time: .omitted)
        let start = episode.startedAt.formatted(date: .omitted, time: .shortened)
        let end = episode.endedAt.formatted(date: .omitted, time: .shortened)
        return start == end ? "\(day), \(start)" : "\(day), \(start)–\(end)"
    }
}
