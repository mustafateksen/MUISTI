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

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        speed = location.speed
        course = location.course
        timestamp = location.timestamp
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
        manager.startUpdatingLocation()
        isRunning = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        isRunning = false
    }

    /// Latest fix if it is younger than `maxAge` (brief: no location older than 10 s).
    func freshFix(maxAge: TimeInterval = 10, now: Date = Date()) -> LocationFix? {
        guard let latest, now.timeIntervalSince(latest.timestamp) <= maxAge else { return nil }
        return latest
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
        geocoder.reverseGeocodeLocation(fix.clLocation) { [weak self] placemarks, _ in
            let name = placemarks?.first?.thoroughfare ?? placemarks?.first?.name
            Task { @MainActor in
                self?.geocodeInFlight = false
                if let name { self?.street = name }
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
