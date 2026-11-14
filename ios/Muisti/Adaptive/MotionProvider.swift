import CoreMotion
import Foundation
import Observation

enum MotionActivityKind: String, Sendable, Codable {
    case unknown, stationary, walking, running, cycling, automotive

    var label: String {
        switch self {
        case .unknown: return String(localized: "unknown", comment: "Motion activity")
        case .stationary: return String(localized: "still", comment: "Motion activity")
        case .walking: return String(localized: "walking", comment: "Motion activity")
        case .running: return String(localized: "running", comment: "Motion activity")
        case .cycling: return String(localized: "cycling", comment: "Motion activity")
        case .automotive: return String(localized: "in vehicle", comment: "Motion activity")
        }
    }
}

/// Phone-side motion: what the wearer is doing (M-coprocessor activity, nearly free),
/// how far they walked (pedometer, works indoors where GPS does not), and whether this
/// instant is steady enough for a sharp photo (device motion at 10 Hz).
///
/// The glasses' own IMU (`MWDATMotion`) is experimental and would cost Bluetooth bandwidth;
/// the phone is a good-enough proxy for "is the wearer moving".
@Observable
@MainActor
final class MotionProvider {
    private(set) var activity: MotionActivityKind = .unknown
    private(set) var stepCount = 0
    /// Pedometer distance since `start()`, metres.
    private(set) var stepDistance: Double = 0
    /// Smoothed user acceleration magnitude, in g.
    private(set) var acceleration: Double = 0
    /// Smoothed rotation rate magnitude, rad/s.
    private(set) var rotation: Double = 0
    /// Body yaw in degrees (arbitrary zero, gravity-aligned). Large changes = turned around.
    private(set) var yawDegrees: Double?
    private(set) var isRunning = false

    var activityAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    var pedometerAvailable: Bool { CMPedometer.isDistanceAvailable() || CMPedometer.isStepCountingAvailable() }
    var deviceMotionAvailable: Bool { motion.isDeviceMotionAvailable }

    @ObservationIgnored private let activityManager = CMMotionActivityManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        stepCount = 0
        stepDistance = 0

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { @Sendable [weak self] activity in
                guard let activity else { return }
                let kind = MotionActivityKind(activity)
                MainActor.assumeIsolated { self?.activity = kind }
            }
        }

        if CMPedometer.isStepCountingAvailable() {
            // Background queue: must not be a main-actor closure (runtime isolation trap).
            pedometer.startUpdates(from: Date()) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.intValue
                // ~0.7 m per step when the pedometer has no distance estimate.
                let distance = data.distance?.doubleValue ?? Double(steps) * 0.7
                Task { @MainActor in
                    self?.stepCount = steps
                    self?.stepDistance = distance
                }
            }
        }

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1   // 10 Hz: enough for a blur gate, cheap
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { @Sendable [weak self] sample, _ in
                guard let sample else { return }
                let a = sample.userAcceleration
                let r = sample.rotationRate
                let accel = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                let rot = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
                let yaw = sample.attitude.yaw * 180 / .pi
                MainActor.assumeIsolated { self?.apply(accel: accel, rot: rot, yaw: yaw) }
            }
        }
    }

    #if DEBUG
    /// A made-up activity, as if the motion coprocessor had reported it (agent evaluation).
    func simulate(_ kind: MotionActivityKind) {
        activity = kind
        isRunning = true
    }
    #endif

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activityManager.stopActivityUpdates()
        pedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
    }

    /// Steady enough for a sharp still right now?
    func isSteady(accelThreshold: Double, rotationThreshold: Double) -> Bool {
        guard motion.isDeviceMotionActive else { return true }
        return acceleration < accelThreshold && rotation < rotationThreshold
    }

    private func apply(accel: Double, rot: Double, yaw: Double) {
        // Fast-attack / slow-release smoothing: one jolt makes it unsteady immediately,
        // it takes a few calm samples to count as steady again.
        acceleration = accel > acceleration ? accel : acceleration * 0.6 + accel * 0.4
        rotation = rot > rotation ? rot : rotation * 0.6 + rot * 0.4
        yawDegrees = yaw
    }
}

extension MotionActivityKind {
    init(_ activity: CMMotionActivity) {
        if activity.automotive { self = .automotive }
        else if activity.cycling { self = .cycling }
        else if activity.running { self = .running }
        else if activity.walking { self = .walking }
        else if activity.stationary { self = .stationary }
        else { self = .unknown }
    }
}
