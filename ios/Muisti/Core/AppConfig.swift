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
    /// Clockwise degrees (0/90/180/270) baked into real-glasses photos. Ray-Ban Meta Gen 2
    /// stills arrive in sensor order with no EXIF orientation; field test 13 Nov: 90° is upright.
    var glassesPhotoRotation: Int = 90
}

/// App-wide settings, persisted in `UserDefaults`, editable from Settings and the debug menu.
@Observable
@MainActor
final class AppConfig {
    static let allowedFPS: [UInt] = [2, 7, 15, 24, 30]

    var sourceKind: SourceKind { didSet { save("sourceKind", sourceKind.rawValue) } }
    var mode: CaptureMode { didSet { save("mode", mode.rawValue) } }
    var streamQuality: StreamQuality { didSet { save("streamQuality", streamQuality.rawValue) } }
    var streamFPS: UInt { didSet { save("streamFPS", Int(streamFPS)) } }
    var stillResolution: StillResolution { didSet { save("stillResolution", stillResolution.rawValue) } }
    var stillQuality: StillQuality { didSet { save("stillQuality", stillQuality.rawValue) } }
    var intervalSeconds: Double { didSet { save("intervalSeconds", intervalSeconds) } }
    var passthroughEveryN: Int { didSet { save("passthroughEveryN", passthroughEveryN) } }
    /// Raw full-size frames to Documents/sessions (dataset for the glasses window only).
    /// Off by default: the plan says raw frames are not kept, only blurred keyframes.
    var recordToDisk: Bool { didSet { save("recordRaw", recordToDisk) } }
    var apiBaseURL: String { didSet { save("apiBaseURL", apiBaseURL) } }
    var chatModel: String { didSet { save("chatModel", chatModel) } }
    var embedModel: String { didSet { save("embedModel", embedModel) } }
    /// Empty = same host as chat.
    var embedBaseURL: String { didSet { save("embedBaseURL", embedBaseURL) } }
    /// Empty = same key as chat. Keychain only.
    var embedKey: String {
        didSet { KeychainStore.write(embedKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "embed-api-key") }
    }
    /// Empty = no reranking.
    var rerankModel: String { didSet { save("rerankModel", rerankModel) } }
    /// Empty = the embedding key (both are NVIDIA build keys). Keychain only.
    var rerankKey: String {
        didSet { KeychainStore.write(rerankKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "rerank-api-key") }
    }
    var retentionDays: Int { didSet { save("retentionDays", retentionDays) } }
    /// Speech recognition is locked to English (not the phone language, not a saved choice).
    /// Answers are spoken in the language Nemotron detects in the question.
    let voiceLocale = "en-US"
    var speakAnswers: Bool { didSet { save("speakAnswers", speakAnswers) } }
    var zones: [NoRecordZone] {
        didSet { if let data = try? JSONEncoder().encode(zones) { defaults.set(data, forKey: "zones") } }
    }
    /// Stored in the Keychain, never in UserDefaults.
    var apiKey: String {
        didSet { KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "nvidia-api-key") }
    }
    var autoReconnect: Bool { didSet { save("autoReconnect", autoReconnect) } }
    var glassesPhotoRotation: Int { didSet { save("glassesPhotoRotation", glassesPhotoRotation) } }
    var tuning: AdaptiveTuning {
        didSet { if let data = try? JSONEncoder().encode(tuning) { defaults.set(data, forKey: "tuning") } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceKind = SourceKind(rawValue: defaults.string(forKey: "sourceKind") ?? "") ?? .glasses
        mode = CaptureMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .adaptive
        streamQuality = StreamQuality(rawValue: defaults.string(forKey: "streamQuality") ?? "") ?? .high
        let fps = UInt(defaults.object(forKey: "streamFPS") as? Int ?? 7)
        streamFPS = Self.allowedFPS.contains(fps) ? fps : 7
        stillResolution = StillResolution(rawValue: defaults.string(forKey: "stillResolution") ?? "") ?? .full
        stillQuality = StillQuality(rawValue: defaults.string(forKey: "stillQuality") ?? "") ?? .medium
        intervalSeconds = defaults.object(forKey: "intervalSeconds") as? Double ?? 5
        passthroughEveryN = defaults.object(forKey: "passthroughEveryN") as? Int ?? 5
        recordToDisk = defaults.object(forKey: "recordRaw") as? Bool ?? false
        apiBaseURL = defaults.string(forKey: "apiBaseURL") ?? NemotronClient.Provider.verda.baseURL.absoluteString
        chatModel = defaults.string(forKey: "chatModel") ?? NemotronClient.Provider.verda.chatModel
        var savedEmbed = defaults.string(forKey: "embedModel") ?? NemotronClient.Provider.verda.embedModel
        if savedEmbed == "nvidia/nemotron-3-embed-1b" { savedEmbed = NemotronClient.Provider.nvidia.embedModel }   // → 3.5, re-embedded in the background
        embedModel = savedEmbed
        embedBaseURL = defaults.string(forKey: "embedBaseURL") ?? ""
        embedKey = KeychainStore.read("embed-api-key") ?? ""
        rerankModel = defaults.string(forKey: "rerankModel") ?? NemotronClient.defaultRerankModel
        rerankKey = KeychainStore.read("rerank-api-key") ?? ""
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 7
        speakAnswers = defaults.object(forKey: "speakAnswers") as? Bool ?? true
        if let data = defaults.data(forKey: "zones"), let decoded = try? JSONDecoder().decode([NoRecordZone].self, from: data) {
            zones = decoded
        } else {
            zones = []
        }
        apiKey = KeychainStore.read("nvidia-api-key") ?? ""
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        glassesPhotoRotation = defaults.object(forKey: "glassesPhotoRotation") as? Int ?? 90
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
            autoReconnect: autoReconnect,
            glassesPhotoRotation: glassesPhotoRotation
        )
    }

    var nemotronSettings: NemotronClient.Settings {
        var s = NemotronClient.Settings()
        s.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" {
            s.baseURL = url
        }
        if !chatModel.isEmpty { s.chatModel = chatModel }
        s.embedModel = embedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: embedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" {
            s.embedBaseURL = url
        }
        s.embedKey = embedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        s.rerankModel = rerankModel.trimmingCharacters(in: .whitespacesAndNewlines)
        s.rerankKey = rerankKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    /// Embeddings from NVIDIA build's hosted Nemotron 3.5 Embed (free key), chat stays where it is.
    /// (Saved embedModel migrates 3-embed → 3.5; the worker re-embeds old rows.)
    func useNVIDIAEmbeddings() {
        embedBaseURL = NemotronClient.Provider.nvidia.baseURL.absoluteString
        embedModel = NemotronClient.Provider.nvidia.embedModel
    }

    /// Embeddings from our own vLLM container on Verda (`--served-model-name nemotron-embed`).
    func useOwnEmbeddingContainer(baseURL: String) {
        embedBaseURL = baseURL
        embedModel = "nemotron-embed"
    }

    func use(_ provider: NemotronClient.Provider) {
        apiBaseURL = provider.baseURL.absoluteString
        chatModel = provider.chatModel
        embedModel = provider.embedModel
        embedBaseURL = ""
    }

    func resetTuning() { tuning = AdaptiveTuning() }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}
