import CoreLocation
import SwiftUI

/// What can be done with what was read: call the number, put a poster's event in the
/// calendar, open its website, write to its e-mail address, find its address, open the place
/// it was seen at in Maps, share it. Each button only appears when the frame's text has it.
struct MemoryQuickActions: View {
    let record: MemoryRecord
    let coordinate: CLLocationCoordinate2D?
    @State private var found: MemoryDetections?
    @State private var addingEvent = false

    var body: some View {
        let found = found ?? MemoryDetections(record: record)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
            if let phone = found.phone, let url = Self.telURL(phone) {
                Link(destination: url) {
                    action(String(localized: "Call"), systemImage: "phone.fill")
                }
                .tint(.success)
            }
            if found.event != nil {
                Button {
                    addingEvent = true
                } label: {
                    action(String(localized: "Calendar"), systemImage: "calendar.badge.plus")
                }
                .tint(.orange)
            }
            if let website = found.website {
                Link(destination: website) {
                    action(String(localized: "Website"), systemImage: "safari.fill")
                }
                .tint(.indigo)
            }
            if let email = found.email {
                Link(destination: email) {
                    action(String(localized: "Email"), systemImage: "envelope.fill")
                }
                .tint(.teal)
            }
            if let address = found.address, let url = Self.searchURL(address) {
                Link(destination: url) {
                    action(String(localized: "Address"), systemImage: "signpost.right.fill")
                }
                .tint(.brandSky)
            }
            if let mapsURL {
                Link(destination: mapsURL) {
                    action(String(localized: "Maps"), systemImage: "map.fill")
                }
                .tint(.brandSky)
            }
            ShareLink(item: shareText(found)) {
                action(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.inner))
        .task(id: record.id) { self.found = MemoryDetections(record: record) }
        .sheet(isPresented: $addingEvent) {
            if let event = found.event {
                CalendarEventSheet(title: record.name ?? record.title, event: event,
                                   location: found.address ?? record.street, notes: record.ocrText)
                    .ignoresSafeArea()
            }
        }
    }

    private func action(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.footnote.bold()).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    /// Where the frame was seen.
    private var mapsURL: URL? {
        guard let coordinate else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: record.name ?? record.title),
        ]
        return components?.url
    }

    /// An address printed on the sign or poster (the event's venue, not where it was seen).
    private static func searchURL(_ address: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        return components?.url
    }

    private func shareText(_ found: MemoryDetections) -> String {
        var lines = [record.name ?? record.title, found.phone, record.hours]
        if let event = found.event { lines.append(event.start.formatted(date: .complete, time: .shortened)) }
        lines += [found.address, found.website?.absoluteString, record.street]
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private static func telURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}
