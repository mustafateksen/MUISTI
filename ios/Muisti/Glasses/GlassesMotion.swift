import Foundation
import MWDATCore
import MWDATMotion
import simd

/// The glasses' own IMU (`MWDATMotion`, experimental in DAT 1.0) at 10 Hz: where the wearer's
/// head points and whether it is moving. The camera sits on the head, so this — not the phone
/// in a pocket — says when the view changed and when a still would be sharp.
///
/// Units are normalised so the scheduler does not depend on the SDK's conventions:
/// acceleration in g (gravity estimated with a low-pass filter and removed), rotation in
/// rad/s (from the orientation quaternion when present, else the gyroscope).
@MainActor
final class GlassesMotion {
    /// Latest head orientation (SDK quaternion, or the gyroscope integrated when absent).
    private(set) var orientation: simd_quatf?
    /// Smoothed head rotation rate, rad/s (fast attack, slow release).
    private(set) var rotation: Double = 0
    /// Smoothed head acceleration without gravity, g (fast attack, slow release).
    private(set) var acceleration: Double = 0
    /// RMS of head acceleration over the last ~2 s, g: walking bobs the head, standing does not.
    private(set) var energy: Double = 0
    private var lastSampleAt: Date?

    private var motion: Motion?
    private var task: Task<Void, Never>?
    private var gravity: SIMD3<Float>?
    private var lastTimestampNs: Int64?
    private var integrated = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    private var meanSquare: Double = 0

    /// Samples arrived within the last 1.5 s.
    var isLive: Bool { lastSampleAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false }

    func isSteady(rotationThreshold: Double, accelThreshold: Double) -> Bool {
        rotation < rotationThreshold && acceleration < accelThreshold
    }

    /// Starts the IMU on a started session. Failure is fine: the phone's sensors stand in.
    func attach(to session: DeviceSession) {
        guard motion == nil else { return }
        do throws(DeviceSessionError) {
            guard let newMotion = try session.addMotion(configuration: MotionConfiguration(samplingRate: .hz10)) else {
                Log.glasses.info("glasses motion unavailable on this device")
                return
            }
            motion = newMotion
            let samples = newMotion.samples
            task = Task { [weak self] in
                for await sample in samples {
                    guard let self else { return }
                    self.apply(sample)
                }
            }
            newMotion.start()
            Log.glasses.info("glasses motion started (10 Hz)")
        } catch {
            Log.glasses.info("glasses motion not added: \(error.description, privacy: .public)")
        }
    }

    func detach() {
        task?.cancel()
        task = nil
        motion?.stop()
        motion = nil
        orientation = nil
        lastSampleAt = nil
        lastTimestampNs = nil
        gravity = nil
        rotation = 0
        acceleration = 0
        energy = 0
        meanSquare = 0
    }

    private func apply(_ sample: MotionSample) {
        let dt: Float = lastTimestampNs.map { Float(max(0, min(0.5, Double(sample.timestampNs - $0) / 1e9))) } ?? 0.1
        lastTimestampNs = sample.timestampNs
        lastSampleAt = Date()

        // Rotation rate and orientation.
        var rate: Double?
        if let q = sample.orientation?.simd {
            let q = simd_normalize(q)
            if let previous = orientation, dt > 0 {
                rate = Double(Self.angle(previous, q)) / Double(dt)
            }
            orientation = q
        } else if let w = sample.gyroscope?.simd {
            rate = Double(simd_length(w))
            let angle = simd_length(w) * dt
            if angle > 0 {
                integrated = simd_normalize(integrated * simd_quatf(angle: angle, axis: simd_normalize(w)))
            }
            orientation = integrated
        }
        if let rate {
            rotation = rate > rotation ? rate : rotation * 0.6 + rate * 0.4
        }

        // Acceleration without gravity, in g whatever the SDK's unit (g or m/s²).
        if let a = sample.accelerometer?.simd {
            let g = gravity.map { $0 * 0.9 + a * 0.1 } ?? a
            gravity = g
            let scale = max(0.5, simd_length(g))
            let dynamic = Double(simd_length(a - g) / scale)
            acceleration = dynamic > acceleration ? dynamic : acceleration * 0.6 + dynamic * 0.4
            meanSquare = meanSquare * 0.95 + dynamic * dynamic * 0.05   // ~2 s at 10 Hz
            energy = meanSquare.squareRoot()
        }
    }

    /// Angle between two orientations, radians.
    static func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let d = min(1, abs(simd_dot(a.vector, b.vector)))
        return 2 * acos(d)
    }
}
