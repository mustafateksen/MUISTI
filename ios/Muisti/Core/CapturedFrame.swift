import CoreGraphics
import CoreLocation
import Foundation

/// Where a frame physically came from.
enum CaptureOrigin: String, Codable, Sendable {
    case glassesStream
    case glassesPhoto
    case mockDevice
    case phoneCamera
}

/// Why a frame was taken. Stream frames are `.stream`; everything else was decided by
/// the adaptive scheduler, a fixed interval, or a person.
enum CaptureTrigger: String, Codable, Sendable {
    case stream          // continuous stream frame (modes A/B)
    case firstFrame      // first still after start
    case distance        // walked/moved far enough since last still
    case heading         // turned (course or body yaw changed)
    case dwell           // stopped moving: probably looking at something
    case interval        // longest allowed gap elapsed while moving
    case idleRefresh     // long stationary refresh
    case fixedInterval   // mode C
    case followUp        // perception line asked for another look (e.g. text detected)
    case manual          // "Şimdi çek" button
    case highRes         // explicit high-resolution request
}

/// The single data type that crosses from the capture line (Kişi 1) to the
/// perception line (Kişi 2). Everything is value-typed and `Sendable`.
struct CapturedFrame: Sendable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let origin: CaptureOrigin
    /// Compressed frame. Kişi 2 makes a `CGImage` from here.
    let jpeg: Data
    let pixelSize: CGSize
    /// True for photos (stream-photo or standalone photo), false for stream frames.
    let isHighRes: Bool
    var trigger: CaptureTrigger

    // Context, filled by `CaptureController` from `LocationProvider`.
    // Kept as plain doubles so the struct stays trivially Sendable.
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var headingDegrees: Double?
    var speedMps: Double?

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        origin: CaptureOrigin,
        jpeg: Data,
        pixelSize: CGSize,
        isHighRes: Bool,
        trigger: CaptureTrigger
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.origin = origin
        self.jpeg = jpeg
        self.pixelSize = pixelSize
        self.isHighRes = isHighRes
        self.trigger = trigger
    }

    var location: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
