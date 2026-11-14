import CoreLocation
import Foundation
import MapKit

/// Where something is, for the agent: the user's named places first, then Apple Maps (only
/// when the user allows map look-ups; the place words leave the phone, nothing else does).
enum Places {
    struct Found: Sendable {
        var name: String
        var latitude: Double
        var longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    /// Places matching the words, nearest first, within `radius` metres of `near`.
    static func search(_ words: String, near: CLLocationCoordinate2D, radius: Double) async -> [Found] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = words
        request.region = MKCoordinateRegion(center: near, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let here = CLLocation(latitude: near.latitude, longitude: near.longitude)
        return response.mapItems.compactMap { item -> Found? in
            let c = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            return Found(name: item.name ?? words, latitude: c.latitude, longitude: c.longitude)
        }
        .filter { $0.location.distance(from: here) <= radius }
        .sorted { $0.location.distance(from: here) < $1.location.distance(from: here) }
    }

    /// The area a place name stands for, for searching the memory by place: the spot the user
    /// is at ("here"), one of their named places, or what Apple's geocoder knows by that name
    /// (a city or district comes with its own extent). `maps` off: named places and "here" only.
    static func area(_ name: String, known: [NamedPlace], here: LocationFix?, maps: Bool) async -> MemoryArea? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if wanted.caseInsensitiveCompare("here") == .orderedSame {
            guard let here else { return nil }
            return MemoryArea(name: "here", latitude: here.latitude, longitude: here.longitude,
                              radius: MemoryArea.venueRadius + min(max(here.accuracy, 0), 100))
        }
        if let place = known.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return MemoryArea(name: place.name, latitude: place.latitude, longitude: place.longitude,
                              radius: max(place.radius, MemoryArea.venueRadius))
        }
        guard maps else { return nil }
        let found = await withTimeout(seconds: 2.5) { () -> MemoryArea? in
            guard let mark = try await CLGeocoder().geocodeAddressString(wanted).first, let centre = mark.location?.coordinate,
                  CLLocationCoordinate2DIsValid(centre) else { return nil }
            // A city's region is its extent; a single address gets the reach of a venue.
            let extent = (mark.region as? CLCircularRegion)?.radius ?? 0
            return MemoryArea(name: wanted, latitude: centre.latitude, longitude: centre.longitude, radius: max(extent, 150))
        }
        return found ?? nil
    }

    /// Compass bearing from one point to another, degrees.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Where a bearing lies for someone walking on `course`: ahead, to the right, behind…
    /// (English, for the model's prompt; the model words it for the user).
    static func relative(bearing: Double, course: Double?) -> String {
        guard let course else { return compass(bearing) }
        let turn = (bearing - course + 540).truncatingRemainder(dividingBy: 360) - 180
        switch turn {
        case -30...30: return "ahead"
        case 30..<70: return "ahead on the right"
        case 70..<110: return "to the right"
        case 110..<150: return "behind on the right"
        case -70 ..< -30: return "ahead on the left"
        case -110 ..< -70: return "to the left"
        case -150 ..< -110: return "behind on the left"
        default: return "behind"
        }
    }

    static func compass(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return "to the " + names[Int((bearing + 22.5) / 45) % 8]
    }
}

/// Follows the user towards the place they said they are going to: how far, which way, and
/// whether they are walking away from it. All of it is arithmetic on GPS fixes; what to say
/// about it is the judge's call (`Notice`).
struct Navigator: Sendable {
    struct Reading: Sendable { var at: Date; var distance: Double }

    private(set) var readings: [Reading] = []
    private(set) var closest: Double = .infinity
    var lastWarned: Date?
    var targetID: String?

    static let arriveWithin: Double = 35
    static let awayBy: Double = 60
    static let awayFor: TimeInterval = 30
    static let warnEvery: TimeInterval = 180

    enum Event: Sendable, Equatable { case arrived(distance: Double), walkingAway(distance: Double, closest: Double, seconds: Int) }

    mutating func reset(target: String?) {
        readings = []
        closest = .infinity
        lastWarned = nil
        targetID = target
    }

    /// Feeds one fix; returns what, if anything, just became true.
    mutating func update(distance: Double, accuracy: Double, moving: Bool, now: Date) -> Event? {
        readings.append(Reading(at: now, distance: distance))
        readings.removeAll { now.timeIntervalSince($0.at) > 120 }
        if distance <= max(Self.arriveWithin, min(accuracy, 60)) { return .arrived(distance: distance) }
        closest = min(closest, distance)
        guard moving, accuracy <= 40, distance >= closest + Self.awayBy else { return nil }
        // Away from it the whole last half minute, not one noisy fix.
        guard let before = readings.last(where: { now.timeIntervalSince($0.at) >= Self.awayFor }),
              distance > before.distance + 15 else { return nil }
        if let lastWarned, now.timeIntervalSince(lastWarned) < Self.warnEvery { return nil }
        lastWarned = now
        let since = readings.first(where: { $0.distance <= closest + 5 })?.at ?? before.at
        return .walkingAway(distance: distance, closest: closest, seconds: Int(now.timeIntervalSince(since)))
    }
}
