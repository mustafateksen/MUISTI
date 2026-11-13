import Foundation

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
        case .unknown: return "bilinmiyor"
        case .still: return "duruyor"
        case .walking: return "yürüyor"
        case .fast: return "hızlı (bisiklet/araç)"
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
/// 4. **Ceilings.** Never faster than `minInterval`, never more than `maxPerMinute`, and while
///    standing still only a few slow refreshes before going quiet.
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
    private var recent: [Date] = []
    private var stillSince: Date?
    private var movedSinceDwell = false
    private var stationaryStills = 0
    private var followUpRequested = false

    private(set) var movement: Movement = .unknown
    private(set) var factor: Double = 1
    private(set) var lastDecision: SchedulerDecision = .wait("Başlamadı")

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

        // Heat first: critical heat on either device pauses capture altogether.
        if input.phoneThermal == .critical || input.glassesHeat == .critical {
            return .hold("Isı kritik; cihazlar soğuyana kadar kare alınmıyor")
        }
        factor = batteryFactor(input)

        guard let last = lastCaptureAt else { return .capture(.firstFrame) }
        let elapsed = now.timeIntervalSince(last)

        if elapsed < tuning.minInterval * factor {
            return .wait("En kısa aralık doluyor")
        }
        let perMinute = max(1, Int(Double(tuning.maxPerMinute) / factor))
        if recent.count >= perMinute {
            return .hold("Dakika sınırı (\(perMinute)) doldu")
        }
        if followUpRequested {
            return .capture(.followUp)
        }

        let moved = max(input.odometer - odometerAtLast, input.stepDistance - stepsAtLast)
        let turned = turnSinceLast(input)

        switch movement {
        case .walking:
            if moved >= tuning.walkingDistance * factor { return .capture(.distance) }
            if let turned, turned >= tuning.headingChange { return .capture(.heading) }
            if elapsed >= tuning.walkingMaxInterval * factor { return .capture(.interval) }
            return .wait(String(format: "Yürüyor · %.0f/%.0f m", moved, tuning.walkingDistance * factor))

        case .fast:
            if moved >= tuning.fastDistance * factor { return .capture(.distance) }
            if let turned, turned >= tuning.headingChange { return .capture(.heading) }
            if elapsed >= tuning.fastMaxInterval * factor { return .capture(.interval) }
            return .wait(String(format: "Hızlı · %.0f/%.0f m", moved, tuning.fastDistance * factor))

        case .still:
            if let stillSince, movedSinceDwell, now.timeIntervalSince(stillSince) >= tuning.dwellSeconds {
                return .capture(.dwell)
            }
            if stationaryStills >= tuning.stationaryMaxStills {
                return .hold("Duruyorsun; hareket edince devam edecek")
            }
            if let turned, turned >= tuning.headingChange * 1.3 { return .capture(.heading) }
            if elapsed >= tuning.stationaryRefresh * factor { return .capture(.idleRefresh) }
            return .wait("Duruyor")

        case .unknown:
            // No motion data (simulator, permission denied): fall back to distance + timer.
            if moved >= tuning.walkingDistance * factor { return .capture(.distance) }
            if elapsed >= tuning.unknownActivityInterval * factor { return .capture(.interval) }
            return .wait("Hareket verisi yok; zamanlayıcı")
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
        followUpRequested = false
        if trigger == .dwell { movedSinceDwell = false }
        if movement == .still { stationaryStills += 1 }
    }

    // MARK: Pieces

    private func classify(_ input: SchedulerInputs) -> Movement {
        let speed = input.gpsSpeed
        let gpsTrusted = (input.gpsAccuracy ?? .infinity) <= 20
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
