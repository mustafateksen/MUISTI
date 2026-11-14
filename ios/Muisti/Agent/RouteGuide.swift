import CoreLocation
import Foundation
import MapKit

/// A walking route to the user's destination, from Apple Maps' directions service, and where
/// the user is on it: which turn comes next and how far it is, and whether they have left the
/// route. Muisti says each turn through the glasses as the user comes up to it.
///
/// iOS gives an app no way to read a navigation running in Maps or Google Maps, so the route is
/// asked for here (the same service Maps uses); only the two end points leave the phone.
struct RouteGuide: Sendable {
    struct Point: Sendable { var latitude: Double; var longitude: Double }
    struct Step: Sendable {
        /// Apple's own instruction for the manoeuvre at the start of this step, in the phone's language.
        var instruction: String
        var distance: Double
        var path: [Point]
        var start: Point { path.first ?? Point(latitude: 0, longitude: 0) }
    }

    enum Event: Sendable, Equatable {
        case turn(instruction: String, meters: Double)
        case offRoute(meters: Double)
    }

    var name: String
    var steps: [Step]
    var meters: Double
    var seconds: Double
    private(set) var announced: Set<Int> = [0]
    private var awayFixes = 0
    private(set) var current = 0

    static let turnWithin: Double = 28
    static let offRouteBeyond: Double = 45

    /// Walking directions between two points. nil: no route (or no network).
    static func plan(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, name: String) async -> RouteGuide? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        let steps = route.steps.compactMap { step -> Step? in
            let count = step.polyline.pointCount
            guard count > 0 else { return nil }
            var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
            step.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
            return Step(instruction: step.instructions, distance: step.distance,
                        path: coordinates.map { Point(latitude: $0.latitude, longitude: $0.longitude) })
        }
        guard !steps.isEmpty else { return nil }
        return RouteGuide(name: name, steps: steps, meters: route.distance, seconds: route.expectedTravelTime)
    }

    /// The first thing to do, for the summary said when the route is ready.
    var firstInstruction: String? { steps.first { !$0.instruction.isEmpty }?.instruction }

    /// The turn that comes next and how far it is from `here`.
    func upcoming(from here: CLLocation) -> (instruction: String, meters: Double)? {
        guard let index = steps.indices.first(where: { $0 > current && !steps[$0].instruction.isEmpty }) else { return nil }
        return (steps[index].instruction, Self.distance(here, steps[index].start))
    }

    /// What is left of the route from the step the user is on.
    var remainingMeters: Double { steps[min(current, steps.count - 1)...].reduce(0) { $0 + $1.distance } }

    /// Feeds one GPS fix; returns what, if anything, should be said now.
    mutating func update(_ here: CLLocation, accuracy: Double) -> Event? {
        // The step the user is on: the one whose path is nearest (never back to an earlier one
        // unless clearly so: paths of consecutive steps touch).
        var best = (index: current, meters: Double.infinity)
        for index in steps.indices {
            let meters = Self.distance(here, toPath: steps[index].path)
            if meters < best.meters - (index < current ? 10 : 0) { best = (index, meters) }
        }
        if best.meters > Self.offRouteBeyond + min(accuracy, 30) {
            awayFixes += 1
            if awayFixes >= 3 {
                awayFixes = 0
                return .offRoute(meters: best.meters)
            }
            return nil
        }
        awayFixes = 0
        current = best.index
        // The next turn, said once, when the user is nearly at it.
        let next = current + 1
        guard next < steps.count, !announced.contains(next), !steps[next].instruction.isEmpty else { return nil }
        let meters = Self.distance(here, steps[next].start)
        guard meters <= Self.turnWithin + min(accuracy, 15) else { return nil }
        announced.insert(next)
        return .turn(instruction: steps[next].instruction, meters: meters)
    }

    // MARK: Geometry (flat-earth, fine for a few hundred metres)

    static func distance(_ here: CLLocation, _ point: Point) -> Double {
        here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
    }

    static func distance(_ here: CLLocation, toPath path: [Point]) -> Double {
        guard path.count > 1 else { return path.first.map { distance(here, $0) } ?? .infinity }
        let lat0 = here.coordinate.latitude * .pi / 180
        func xy(_ p: Point) -> (x: Double, y: Double) {
            ((p.longitude - here.coordinate.longitude) * 111_320 * cos(lat0), (p.latitude - here.coordinate.latitude) * 111_320)
        }
        var best = Double.infinity
        for i in 0..<(path.count - 1) {
            let a = xy(path[i]), b = xy(path[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / length)) : 0
            let px = a.x + t * dx, py = a.y + t * dy
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }
}
