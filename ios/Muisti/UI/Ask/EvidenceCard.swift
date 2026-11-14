import MapKit
import SwiftUI

/// One remembered frame: blurred keyframe, when and where, a map pin. The raw OCR text is not
/// shown here; the answer above already quotes what matters.
struct EvidenceCard: View {
    let hit: MemoryHit
    let store: MemoryStore

    var body: some View {
        let record = hit.record
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            KeyframeImage(url: store.frameURL(record), maxPixel: 900, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: Theme.Radius.inner))
                .opensPhotoViewer(url: store.frameURL(record), title: record.name ?? record.title)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(record.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Label(record.seenAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                if let street = record.street {
                    Label(distanceText.map { "\(street) · \($0)" } ?? street, systemImage: "mappin.and.ellipse")
                } else if let distanceText {
                    Label(distanceText, systemImage: "location")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let lat = record.latitude, let lon = record.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))) {
                    Marker(record.name ?? record.kind ?? "Seen", coordinate: coordinate)
                }
                .frame(height: 130)
                .clipShape(.rect(cornerRadius: Theme.Radius.inner))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.s)
        .background(.background, in: .rect(cornerRadius: Theme.Radius.inner + Theme.Spacing.s))
    }

    private var distanceText: String? {
        hit.distanceMeters.map {
            Measurement(value: $0, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
        }
    }
}
