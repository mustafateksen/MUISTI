import Foundation
import Observation

/// How frames are captured.
enum CaptureMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Default. No continuous video: the glasses camera sits idle with only the photo
    /// capability up, and the adaptive scheduler decides each still from phone GPS,
    /// pedometer, motion activity, turning, blur risk, battery and heat.
    case adaptive
    /// A: continuous low-rate stream (`.raw`, 2 or 7 fps).
    case stream
    /// B: stream A plus on-demand `stream.capturePhoto` (Kişi 2 asks when it sees text).
    case streamPlusPhoto
    /// C: no stream, a standalone photo every N seconds (baseline for battery tests).
    case intervalPhoto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "Uyarlamalı (önerilen)"
        case .stream: return "A · Düşük hızlı akış"
        case .streamPlusPhoto: return "B · Akış + tetiklenen fotoğraf"
        case .intervalPhoto: return "C · Aralıklı fotoğraf"
        }
    }

    /// Modes that keep the glasses camera on the photo capability instead of a stream.
    var usesPhotoCapability: Bool { self == .adaptive || self == .intervalPhoto }
    /// Modes whose stills are decided by the scheduler loop.
    var usesScheduler: Bool { self == .adaptive || self == .intervalPhoto }
}

enum StreamQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "Yüksek 720×1280"
        case .medium: return "Orta 504×896"
        case .low: return "Düşük 360×640"
        }
    }
}

enum StillResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case small, medium, large, full
    var id: String { rawValue }
}

enum StillQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
}

/// Tunables for the adaptive scheduler. Distances in metres, times in seconds.
struct AdaptiveTuning: Codable, Sendable, Equatable {
    var minInterval: Double = 3            // never faster than this (transfer + battery)
    var maxPerMinute: Int = 15             // plan: 10–15 kept frames per minute
    var walkingDistance: Double = 10       // new still every ~10 m walked
    var walkingMaxInterval: Double = 8     // ...or every 8 s while walking
    var fastDistance: Double = 30          // cycling / vehicle
    var fastMaxInterval: Double = 4
    var headingChange: Double = 35         // degrees; course or body yaw
    var dwellSeconds: Double = 1.5         // stopped this long after moving → one still
    var stationaryRefresh: Double = 45     // standing still: refresh this rarely
    var stationaryMaxStills: Int = 3       // ...and stop after this many until moving again
    var unknownActivityInterval: Double = 8 // no motion data (simulator): plain timer
    var blurGateMaxWait: Double = 1.2      // wait at most this long for a steady moment
    var blurAccelThreshold: Double = 0.18  // g, user acceleration magnitude
    var blurRotationThreshold: Double = 1.2 // rad/s
    var batterySaver: Bool = true          // stretch intervals on low battery / heat
}

/// Snapshot handed to a source at start. Plain value; safe to send anywhere.
struct CaptureConfig: Sendable, Equatable {
    var mode: CaptureMode
    var streamQuality: StreamQuality
    var streamFPS: UInt
    var stillResolution: StillResolution
    var stillQuality: StillQuality
    var autoReconnect: Bool
}

/// App-wide settings, persisted in `UserDefaults`, editable from Settings and the debug menu.
@Observable
@MainActor
final class AppConfig {
    static let allowedFPS: [UInt] = [2, 7, 15, 24, 30]

    var serverBaseURL: String { didSet { save("serverBaseURL", serverBaseURL) } }
    var sourceKind: SourceKind { didSet { save("sourceKind", sourceKind.rawValue) } }
    var mode: CaptureMode { didSet { save("mode", mode.rawValue) } }
    var streamQuality: StreamQuality { didSet { save("streamQuality", streamQuality.rawValue) } }
    var streamFPS: UInt { didSet { save("streamFPS", Int(streamFPS)) } }
    var stillResolution: StillResolution { didSet { save("stillResolution", stillResolution.rawValue) } }
    var stillQuality: StillQuality { didSet { save("stillQuality", stillQuality.rawValue) } }
    var intervalSeconds: Double { didSet { save("intervalSeconds", intervalSeconds) } }
    var passthroughEveryN: Int { didSet { save("passthroughEveryN", passthroughEveryN) } }
    var recordToDisk: Bool { didSet { save("recordToDisk", recordToDisk) } }
    var uploadEnabled: Bool { didSet { save("uploadEnabled", uploadEnabled) } }
    var autoReconnect: Bool { didSet { save("autoReconnect", autoReconnect) } }
    var tuning: AdaptiveTuning {
        didSet { if let data = try? JSONEncoder().encode(tuning) { defaults.set(data, forKey: "tuning") } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverBaseURL = defaults.string(forKey: "serverBaseURL") ?? "http://192.168.1.10:8000"
        sourceKind = SourceKind(rawValue: defaults.string(forKey: "sourceKind") ?? "") ?? .glasses
        mode = CaptureMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .adaptive
        streamQuality = StreamQuality(rawValue: defaults.string(forKey: "streamQuality") ?? "") ?? .high
        let fps = UInt(defaults.object(forKey: "streamFPS") as? Int ?? 7)
        streamFPS = Self.allowedFPS.contains(fps) ? fps : 7
        stillResolution = StillResolution(rawValue: defaults.string(forKey: "stillResolution") ?? "") ?? .full
        stillQuality = StillQuality(rawValue: defaults.string(forKey: "stillQuality") ?? "") ?? .medium
        intervalSeconds = defaults.object(forKey: "intervalSeconds") as? Double ?? 5
        passthroughEveryN = defaults.object(forKey: "passthroughEveryN") as? Int ?? 5
        recordToDisk = defaults.object(forKey: "recordToDisk") as? Bool ?? true
        uploadEnabled = defaults.object(forKey: "uploadEnabled") as? Bool ?? true
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        if let data = defaults.data(forKey: "tuning"),
           let decoded = try? JSONDecoder().decode(AdaptiveTuning.self, from: data) {
            tuning = decoded
        } else {
            tuning = AdaptiveTuning()
        }
    }

    var captureConfig: CaptureConfig {
        CaptureConfig(
            mode: mode,
            streamQuality: streamQuality,
            streamFPS: streamFPS,
            stillResolution: stillResolution,
            stillQuality: stillQuality,
            autoReconnect: autoReconnect
        )
    }

    var serverURL: URL? {
        URL(string: serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func resetTuning() { tuning = AdaptiveTuning() }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}
