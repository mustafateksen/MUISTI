import BackgroundTasks
import CoreLocation
import Foundation

/// Keeps the agent reachable while Muisti is not in front and not capturing: with "Always"
/// location access the system wakes the app when the user has moved a good way, arrived
/// somewhere or left (visits), or entered a place an intent is waiting for; a background refresh
/// lets it look at the calendar now and then. Each wake runs one agent tick, which can only end
/// in a notification (nothing is spoken from the background unless capture is running).
///
/// Without "Always" access none of this runs; reminders with a time or a place still arrive
/// through the notifications scheduled with the system (`AgentNotifications.schedule`).
@MainActor
final class BackgroundRuntime: NSObject, CLLocationManagerDelegate {
    static let refreshTask = "fi.junction.powerpuffboys.muisti.agent.refresh"

    private let manager = CLLocationManager()
    /// Called with the position that woke the app (nil: a background refresh).
    var onWake: ((CLLocation?) async -> Void)?
    private(set) var authorization: CLAuthorizationStatus

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAlways: Bool { authorization == .authorizedAlways }

    /// Asks for "Always" (the system shows its own sheet; from "While Using" it is an upgrade).
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard isAlways else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = true
        if CLLocationManager.significantLocationChangeMonitoringAvailable() { manager.startMonitoringSignificantLocationChanges() }
        manager.startMonitoringVisits()
    }

    func stop() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.monitoredRegions.forEach(manager.stopMonitoring(for:))
    }

    /// The places worth a wake-up, nearest first; the system allows 20 per app, 18 are used.
    func watch(_ places: [(id: String, coordinate: CLLocationCoordinate2D, radius: Double)], near: CLLocation?) {
        guard isAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let sorted = near.map { here in
            places.sorted { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: here)
                < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: here) }
        } ?? places
        let wanted = Dictionary(sorted.prefix(18).map { ("agent." + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for region in manager.monitoredRegions where region.identifier.hasPrefix("agent.") && wanted[region.identifier] == nil {
            manager.stopMonitoring(for: region)
        }
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for (identifier, place) in wanted where !existing.contains(identifier) {
            let region = CLCircularRegion(center: place.coordinate, radius: min(max(place.radius, 100), manager.maximumRegionMonitoringDistance), identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    // MARK: Background refresh

    /// Must be called before the app finishes launching.
    func registerRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                let work = Task { await self?.onWake?(nil) }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            Trace.note("agent wake: moved")
            await self.onWake?(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let location = CLLocation(coordinate: visit.coordinate, altitude: 0, horizontalAccuracy: visit.horizontalAccuracy, verticalAccuracy: -1, timestamp: Date())
        let left = visit.departureDate != .distantFuture
        Task { @MainActor in
            Trace.note("agent wake: \(left ? "left a place" : "arrived at a place")")
            await self.onWake?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circle = region as? CLCircularRegion else { return }
        let location = CLLocation(coordinate: circle.center, altitude: 0, horizontalAccuracy: min(circle.radius, 60), verticalAccuracy: -1, timestamp: Date())
        let identifier = region.identifier
        Task { @MainActor in
            Trace.note("agent wake: entered \(identifier)")
            await self.onWake?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
