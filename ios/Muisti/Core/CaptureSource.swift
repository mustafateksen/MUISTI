import Foundation

/// User-facing state of a capture source. Every case maps to one line on screen and
/// one next step for the user.
enum CaptureState: Equatable, Sendable {
    case idle
    case needsRegistration
    case needsPermission
    case waitingForDevice          // glasses off, out of range, hinge closed
    case starting
    case running
    case paused(reason: String)    // cap-touch tap, other experience, doffed, backgrounded
    case failed(message: String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .paused, .waitingForDevice: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Hazır"
        case .needsRegistration: return "Meta AI ile bağlantı gerekli"
        case .needsPermission: return "Kamera izni gerekli"
        case .waitingForDevice: return "Gözlük bekleniyor"
        case .starting: return "Başlatılıyor"
        case .running: return "Kayıtta"
        case .paused(let reason): return "Duraklatıldı: \(reason)"
        case .failed(let message): return "Hata: \(message)"
        }
    }
}

enum SourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case glasses
    case phone

    var id: String { rawValue }
    var label: String {
        switch self {
        case .glasses: return "Gözlük"
        case .phone: return "Telefon kamerası"
        }
    }
}

/// One capture interface for real glasses, MockDeviceKit glasses and the phone camera.
///
/// Two ways frames leave a source:
/// - `frames`: continuous stream frames (modes A/B). Single consumer: `CaptureController`.
/// - `captureStill(trigger:)`: one frame on demand. The adaptive scheduler uses this, so
///   the glasses never have to keep a power-hungry video stream open.
@MainActor
protocol CaptureSource: AnyObject {
    var kind: SourceKind { get }
    var state: CaptureState { get }
    var frames: AsyncStream<CapturedFrame> { get }
    var states: AsyncStream<CaptureState> { get }

    func start(config: CaptureConfig) async
    func stop() async

    /// Cheapest single still the source can give right now (photo capability on glasses,
    /// latest frame on the phone). `nil` if not ready or the capture failed.
    func captureStill(trigger: CaptureTrigger) async -> CapturedFrame?

    /// Highest-resolution single still, if supported.
    func requestHighResPhoto() async -> CapturedFrame?
}
