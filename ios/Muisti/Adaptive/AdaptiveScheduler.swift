import Foundation
import simd

/// Everything the scheduler looks at, gathered once per tick. Plain values: easy to log,
/// easy to unit-test, no sensors needed.
struct SchedulerInputs: Sendable {
    var now: Date
    var activity: MotionActivityKind
    var gpsSpeed: Double?          // m/s, nil if unknown
    var gpsCourse: Double?         // degrees, only while moving
    var gpsAccuracy: Double?
    var odometer: Double           // GPS metres since start
    var stepDistance: Double       // pedometer metres since start (indoors)
    var yawDegrees: Double?        // phone body yaw
    var headOrientation: simd_quatf?   // glasses IMU, nil when not streaming
    var headRotation: Double?      // glasses rotation rate, rad/s
    var headEnergy: Double?        // glasses acceleration RMS, g
    var phoneBattery: Double?      // 0...1
    var phoneLowPower: Bool
    var phoneThermal: ProcessInfo.ThermalState
    var glassesBattery: Int?       // 0...100
    var glassesHeat: HeatLevel
}

enum HeatLevel: Int, Sendable, Comparable {
    case normal = 0, warm, hot, critical
    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }
}

enum Movement: String, Sendable {
    case unknown, still, walking, fast

    var label: String {
        switch self {
        case .unknown: return String(localized: "unknown", comment: "Motion activity")
        case .still: return String(localized: "still", comment: "Motion activity")
        case .walking: return String(localized: "walking", comment: "Motion activity")
        case .fast: return String(localized: "fast (bike/vehicle)")
        }
    }
}

enum SchedulerDecision: Equatable, Sendable {
    case capture(CaptureTrigger)
    case wait(String)
    case hold(String)      // deliberately not capturing (heat, rate cap)
}

/// The adaptive capture policy. Pure logic: feed it `SchedulerInputs`, it says capture or wait.
///
/// Ideas, in order of what saves the most battery:
/// 1. **Distance, not time.** A new still every ~10 m walked (GPS outdoors, pedometer indoors).
///    Standing still costs nothing; walking fast does not produce duplicates.
/// 2. **Dwell.** When someone walking stops for ~1.5 s they are usually looking at something
///    (a sign, a menu, a stand). That moment gets one still.
/// 3. **Turns.** A course or body-yaw change of ~35° means a new view.
/// 4. **Head view.** With the glasses IMU: the head turned ≥ `viewChange`° since the last still
///    and has settled → the wearer is looking at something new. Walking is read from head bob.
/// 5. **Ceilings.** Never faster than `minInterval`, never more than `maxPerMinute`. Standing
///    still never stops capture: a refresh every `stationaryRefresh`, slower after a while.
/// 5. **Battery and heat stretch everything.** Low phone/glasses battery or heat multiplies
///    intervals and distances; critical heat pauses capture.
/// 6. **Blur gate** (in `CaptureController`): once a still is due, wait up to ~1 s for a calm
///    instant between steps, so the frame that crosses Bluetooth is worth keeping.
struct AdaptiveScheduler: Sendable {
    var tuning: AdaptiveTuning

    // Memory
    private(set) var lastCaptureAt: Date?
    private var odometerAtLast: Double = 0
    private var stepsAtLast: Double = 0
    private var courseAtLast: Double?
    private var yawAtLast: Double?
    private var headAtLast: simd_quatf?
    private var headSettledSince: Date?
    private var recent: [Date] = []
    private var stillSince: Date?
    private var movedSinceDwell = false
    private var stationaryStills = 0
    private var followUpRequested = false

    private(set) var movement: Movement = .unknown
    private(set) var factor: Double = 1
    private(set) var lastDecision: SchedulerDecision = .wait("Not started")

    init(tuning: AdaptiveTuning) {
        self.tuning = tuning
    }

    mutating func reset() {
        self = AdaptiveScheduler(tuning: tuning)
    }

    /// Kişi 2 can ask for another look soon (e.g. text found but blurry).
    mutating func requestFollowUp() { followUpRequested = true }

    var capturesLastMinute: Int { recent.count }

    // MARK: Decide

    mutating func decide(_ input: SchedulerInputs) -> SchedulerDecision {
        let decision = evaluate(input)
        lastDecision = decision
        return decision
    }

    private mutating func evaluate(_ input: SchedulerInputs) -> SchedulerDecision {
        let now = input.now
        recent.removeAll { now.timeIntervalSince($0) > 60 }
        movement = classify(input)
        trackMovement(now)
        trackHead(input)

        // Heat first: critical heat on either device pauses capture altogether.
        if input.phoneThermal == .critical || input.glassesHeat == .critical {
            return .hold(String(localized: "Heat critical; no frames until devices cool down"))
        }
        factor = batteryFactor(input)

        guard let last = lastCaptureAt else { return .capture(.firstFrame) }
        let elapsed = now.timeIntervalSince(last)

        if elapsed < tuning.minInterval * factor {
            return .wait(String(localized: "Waiting for minimum interval"))
        }
        let perMinute = max(1, Int(Double(tuning.maxPerMinute) / factor))
        if recent.count >= perMinute {
            return .hold(String(localized: "Per-minute limit (\(perMinute)) reached"))
        }
        if followUpRequested {
            return .capture(.followUp)
        }

        let moved = max(input.odometer - odometerAtLast, input.stepDistance - stepsAtLast)
        let turned = turnSinceLast(input)

        // Looking at something new: the head turned and has held still there.
        if let view = viewChangeSinceLast(input), view >= tuning.viewChange,
           let settled = headSettledSince, now.timeIntervalSince(settled) >= tuning.lookSettle {
            return .capture(.heading)
        }

        switch movement {
        case .walking:
            if moved >= tuning.walkingDistance * factor { return .capture(.distance) }
            if let turned, turned >= tuning.headingChange { return .capture(.heading) }
            if elapsed >= tuning.walkingMaxInterval * factor { return .capture(.interval) }
            return .wait(String(format: String(localized: "Walking · %.0f/%.0f m"), moved, tuning.walkingDistance * factor))

        case .fast:
            if moved >= tuning.fastDistance * factor { return .capture(.distance) }
            if let turned, turned >= tuning.headingChange { return .capture(.heading) }
            if elapsed >= tuning.fastMaxInterval * factor { return .capture(.interval) }
            return .wait(String(format: String(localized: "Fast · %.0f/%.0f m"), moved, tuning.fastDistance * factor))

        case .still:
            if let stillSince, movedSinceDwell, now.timeIntervalSince(stillSince) >= tuning.dwellSeconds {
                return .capture(.dwell)
            }
            if input.headOrientation == nil, let turned, turned >= tuning.headingChange * 1.3 {
                return .capture(.heading)
            }
            // Never goes quiet; after a few refreshes of the same view, refresh more slowly.
            let refresh = tuning.stationaryRefresh * factor * (stationaryStills >= tuning.stationaryMaxStills ? 2.5 : 1)
            if elapsed >= refresh { return .capture(.idleRefresh) }
            return .wait(String(format: String(localized: "Still · next in %.0f s"), max(0, refresh - elapsed)))

        case .unknown:
            // No motion data (simulator, permission denied): fall back to distance + timer.
            if moved >= tuning.walkingDistance * factor { return .capture(.distance) }
            if elapsed >= tuning.unknownActivityInterval * factor { return .capture(.interval) }
            return .wait(String(localized: "No motion data; using timer"))
        }
    }

    /// Call after a still actually arrived.
    mutating func didCapture(_ trigger: CaptureTrigger, input: SchedulerInputs) {
        lastCaptureAt = input.now
        recent.append(input.now)
        odometerAtLast = input.odometer
        stepsAtLast = input.stepDistance
        courseAtLast = input.gpsCourse ?? courseAtLast
        yawAtLast = input.yawDegrees ?? yawAtLast
        headAtLast = input.headOrientation ?? headAtLast
        followUpRequested = false
        if trigger == .dwell { movedSinceDwell = false }
        if movement == .still { stationaryStills += 1 }
    }

    // MARK: Pieces

    private func classify(_ input: SchedulerInputs) -> Movement {
        let speed = input.gpsSpeed
        let gpsTrusted = (input.gpsAccuracy ?? .infinity) <= 20
        // The glasses are on the head: head bob says walking even with the phone on a table.
        if let energy = input.headEnergy, input.activity != .automotive, input.activity != .cycling {
            if gpsTrusted, let speed, speed > 4 { return .fast }
            return energy >= tuning.headWalkingEnergy ? .walking : .still
        }
        switch input.activity {
        case .automotive, .cycling:
            return .fast
        case .walking, .running:
            return .walking
        case .stationary:
            // Activity lags a few seconds; trust a clearly moving GPS over it.
            if gpsTrusted, let speed, speed > 1.0 { return speed > 4 ? .fast : .walking }
            return .still
        case .unknown:
            guard gpsTrusted, let speed else { return .unknown }
            if speed > 4 { return .fast }
            if speed > 0.6 { return .walking }
            return .still
        }
    }

    private mutating func trackMovement(_ now: Date) {
        switch movement {
        case .walking, .fast:
            stillSince = nil
            movedSinceDwell = true
            stationaryStills = 0
        case .still:
            if stillSince == nil { stillSince = now }
        case .unknown:
            break
        }
    }

    /// Head held still (glasses IMU) since when; nil while it moves or without glasses data.
    private mutating func trackHead(_ input: SchedulerInputs) {
        guard let rate = input.headRotation else {
            headSettledSince = nil
            return
        }
        if rate >= tuning.headSteadyRate {
            headSettledSince = nil
        } else if headSettledSince == nil {
            headSettledSince = input.now
        }
    }

    /// Degrees the head turned since the last still (glasses orientation).
    private func viewChangeSinceLast(_ input: SchedulerInputs) -> Double? {
        guard let now = input.headOrientation, let then = headAtLast else { return nil }
        let d = min(1, abs(simd_dot(now.vector, then.vector)))
        return Double(2 * acos(d)) * 180 / .pi
    }

    /// Degrees turned since the last still: GPS course while moving, else phone yaw.
    private func turnSinceLast(_ input: SchedulerInputs) -> Double? {
        if let now = input.gpsCourse, let then = courseAtLast {
            return Self.angleDelta(now, then)
        }
        if let now = input.yawDegrees, let then = yawAtLast {
            return Self.angleDelta(now, then)
        }
        return nil
    }

    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    private func batteryFactor(_ input: SchedulerInputs) -> Double {
        guard tuning.batterySaver else { return 1 }
        var f = 1.0
        if input.phoneLowPower || (input.phoneBattery ?? 1) < 0.2 { f *= 1.5 }
        if let g = input.glassesBattery {
            if g < 10 { f *= 3 } else if g < 20 { f *= 2 }
        }
        if input.phoneThermal == .serious || input.glassesHeat >= .hot { f *= 2 }
        else if input.glassesHeat == .warm { f *= 1.3 }
        return f
    }
}
