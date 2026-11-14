import CoreLocation
import SwiftUI

/// Call the number that was read, open the place in Maps, share what was read.
struct MemoryQuickActions: View {
    let record: MemoryRecord
    let coordinate: CLLocationCoordinate2D?

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let phone = record.phone, let url = Self.telURL(phone) {
                Link(destination: url) {
                    action(String(localized: "Call"), systemImage: "phone.fill")
                }
                .tint(.success)
            }
            if let mapsURL {
                Link(destination: mapsURL) {
                    action(String(localized: "Maps"), systemImage: "map.fill")
                }
                .tint(.brandSky)
            }
            ShareLink(item: shareText) {
                action(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.inner))
    }

    private func action(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.footnote.bold())
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    private var mapsURL: URL? {
        guard let coordinate else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: record.name ?? record.title),
        ]
        return components?.url
    }

    private var shareText: String {
        [record.name ?? record.title, record.phone, record.hours, record.street]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private static func telURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}
