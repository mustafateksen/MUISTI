import CoreLocation
import Foundation
import Observation

struct LocationFix: Sendable, Equatable, Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let speed: Double        // m/s, < 0 means unknown
    let course: Double       // degrees, < 0 means unknown
    let timestamp: Date
    /// Floor from the phone's indoor positioning (only in buildings Apple has mapped).
    var floor: Int?

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        speed = location.speed
        course = location.course
        timestamp = location.timestamp
        floor = location.floor?.level
    }

    /// Walking direction is only trusted above 0.5 m/s; a pocketed phone's compass is not.
    var validCourse: Double? { speed >= 0.5 && course >= 0 ? course : nil }
    var validSpeed: Double? { speed >= 0 ? speed : nil }
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// GPS for frame context and for the scheduler's "how far have I walked" odometer.
/// Runs only while capturing.
@Observable
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var latest: LocationFix?
    private(set) var authorization: CLAuthorizationStatus
    /// Metres travelled since `start()`, summed from accurate fixes only.
    private(set) var odometer: Double = 0
    private(set) var isRunning = false

    /// Every accepted fix, for the recorder's `gps.jsonl` track.
    @ObservationIgnored var onFix: ((LocationFix) -> Void)?

    /// Street name from reverse geocoding, refreshed every ~50 m (Apple rate-limits this).
    private(set) var street: String?
    /// Around the street: the named place or building if the phone knows one, the district and
    /// the city ("Messukeskus, Pasila, Helsinki"). From the same reverse geocoding.
    private(set) var area: String?

    /// The area with the floor, as stored with each memory.
    func areaText(for fix: LocationFix?) -> String? {
        let floor = fix?.floor.map { "floor \($0)" }
        let parts = [area, floor].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Where the user is now, for the answer model: street, area, floor, coordinates.
    func positionText(maxAge: TimeInterval = 120) -> String? {
        guard let fix = freshFix(maxAge: maxAge) else { return nil }
        var parts: [String] = []
        if let street { parts.append("street: \(street)") }
        if let area { parts.append("area: \(area)") }
        if let floor = fix.floor { parts.append("floor \(floor) (phone's indoor positioning)") }
        parts.append(String(format: "coordinates %.4f, %.4f (±%d m)", fix.latitude, fix.longitude, Int(fix.accuracy.rounded())))
        return parts.joined(separator: "; ")
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var lastGeocoded: LocationFix?
    @ObservationIgnored private var geocodeInFlight = false
    @ObservationIgnored private var lastOdometerFix: LocationFix?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // No distance filter: a standing user must keep getting fresh (<10 s) fixes.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        odometer = 0
        lastOdometerFix = nil
        // Keeps GPS (and so the app) running in the background while capturing; the system
        // shows the blue location indicator. Needs the "location" background mode.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isRunning = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }

    /// Fixes of the last two hours, for placing frames recorded in the background.
    @ObservationIgnored private(set) var history: [LocationFix] = []

    func remember(_ fix: LocationFix) {
        history.append(fix)
        let cutoff = fix.timestamp.addingTimeInterval(-2 * 3600)
        if let first = history.first, first.timestamp < cutoff { history.removeAll { $0.timestamp < cutoff } }
    }

    /// The fix closest in time to `date` (within 60 s).
    func fix(near date: Date) -> LocationFix? {
        history.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
            .flatMap { abs($0.timestamp.timeIntervalSince(date)) <= 60 ? $0 : nil }
    }

    /// Latest fix if it is younger than `maxAge` (brief: no location older than 10 s).
    func freshFix(maxAge: TimeInterval = 10, now: Date = Date()) -> LocationFix? {
        guard let latest, now.timeIntervalSince(latest.timestamp) <= maxAge else { return nil }
        return latest
    }

    /// A position that did not come from this provider's own updates: the one that woke the app
    /// in the background (`BackgroundRuntime`), or a made-up one in the agent evaluation.
    func inject(_ location: CLLocation) {
        accept([LocationFix(location)])
    }

    private func accept(_ fixes: [LocationFix]) {
        for fix in fixes where fix.accuracy > 0 {
            latest = fix
            onFix?(fix)
            refreshStreetIfNeeded(fix)
            guard fix.accuracy <= 25 else { continue }
            if let previous = lastOdometerFix {
                let step = fix.clLocation.distance(from: previous.clLocation)
                // Ignore jitter smaller than the combined uncertainty.
                if step >= max(2, (fix.accuracy + previous.accuracy) * 0.3) {
                    odometer += step
                    lastOdometerFix = fix
                }
            } else {
                lastOdometerFix = fix
            }
        }
    }

    private func refreshStreetIfNeeded(_ fix: LocationFix) {
        guard fix.accuracy <= 50, !geocodeInFlight else { return }
        if let last = lastGeocoded,
           fix.clLocation.distance(from: last.clLocation) < 50,
           fix.timestamp.timeIntervalSince(last.timestamp) < 300 { return }
        geocodeInFlight = true
        lastGeocoded = fix
        geocoder.reverseGeocodeLocation(fix.clLocation) { @Sendable [weak self] placemarks, _ in
            let place = placemarks?.first
            let name = place?.thoroughfare ?? place?.name
            // A named place (station, mall, campus) only when it is not just the street address.
            let named = (place?.areasOfInterest?.first).flatMap { $0 == name ? nil : $0 }
            var around: [String] = []
            for part in [named, place?.subLocality, place?.locality].compactMap({ $0 }) where !around.contains(part) {
                around.append(part)
            }
            let area = around.joined(separator: ", ")
            Task { @MainActor in
                self?.geocodeInFlight = false
                if let name { self?.street = name }
                if !area.isEmpty { self?.area = area }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(LocationFix.init)
        MainActor.assumeIsolated { self.accept(fixes) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.motion.error("location error: \(error.localizedDescription, privacy: .public)")
    }
}
