import AVFoundation
import Speech

/// Apple's newer on-device speech models (iOS 26 `SpeechAnalyzer`: `SpeechTranscriber` plus
/// `DictationTranscriber` on the same audio, see `AnalyzerSpeechSession`), for spoken questions. Clearly more accurate than `SFSpeechRecognizer` on published benchmarks
/// (LibriSpeech word error 2–5 % vs 9–16 %). Its language model is downloaded once by the
/// system; until it is installed Muisti keeps using `SFSpeechRecognizer`.
@available(iOS 26, *)
enum AnalyzerSpeech {
    /// What a session needs: the resolved locale and the audio format the model takes.
    struct Prepared: Sendable {
        let locale: Locale
        let format: AVAudioFormat
    }

    private static let cache = Cache()

    /// Ready to transcribe `identifier` now? Starts the model download in the background when
    /// it is missing and returns nil this time.
    static func prepared(_ identifier: String) async -> Prepared? {
        if let hit = await cache.get(identifier) { return hit }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { return nil }
        let probe = modules(locale)
        switch await AssetInventory.status(forModules: probe) {
        case .installed:
            break
        case .supported, .downloading:
            Task.detached(priority: .utility) { await install(locale) }
            return nil
        default:
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: probe) else { return nil }
        let ready = Prepared(locale: locale, format: format)
        await cache.set(identifier, ready)
        return ready
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // Volatile results: words appear while the user speaks; final results replace them.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// The dictation model on the same audio: it takes the names in memory as contextual
    /// strings ("Otakaari", "Harry the K's"), which `SpeechTranscriber` ignores.
    static func makeDictation(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                             reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    static func modules(_ locale: Locale) -> [any SpeechModule] {
        [makeTranscriber(locale), makeDictation(locale)]
    }

    private static func install(_ locale: Locale) async {
        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules(locale)) {
                try await request.downloadAndInstall()
                Log.pipeline.info("speech model installed for \(locale.identifier, privacy: .public)")
            }
        } catch {
            Log.pipeline.error("speech model download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private actor Cache {
        private var prepared: [String: Prepared] = [:]
        func get(_ key: String) -> Prepared? { prepared[key] }
        func set(_ key: String, _ value: Prepared) { prepared[key] = value }
    }
}
