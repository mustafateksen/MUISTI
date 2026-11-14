import AVFoundation

/// Chooses the voice answers are read in. `AVSpeechSynthesisVoice(language:)` returns the
/// compact (robotic) voice; the same language usually has an Enhanced or Premium neural voice on
/// the phone (or one tap away in Settings › Accessibility › Spoken Content › Voices). These run
/// on the device like the compact one, with no extra load worth noticing. Muisti takes the user's
/// choice for the language, else the best installed voice: Premium › Enhanced › default, the
/// phone's own region first, no novelty voices.
enum VoicePicker {
    private static let storageKey = "answerVoices"   // [language code: voice identifier]

    static func voice(for language: String, fallback: String) -> AVSpeechSynthesisVoice? {
        let code = languageCode(language)
        if let id = chosen[code], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return voices(for: language).first ?? voices(for: fallback).first
    }

    /// Installed voices for a language, best first.
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let code = languageCode(language)
        let region = language.contains("-") ? String(language.split(separator: "-").last ?? "")
            : (Locale.current.region?.identifier ?? "")
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { languageCode($0.language) == code }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                let ra = rank(a, region: region), rb = rank(b, region: region)
                return ra != rb ? ra > rb : a.name < b.name
            }
    }

    static func hasNaturalVoice(for language: String) -> Bool {
        voices(for: language).contains { $0.quality != .default }
    }

    static func choose(_ voice: AVSpeechSynthesisVoice?, for language: String) {
        var map = chosen
        map[languageCode(language)] = voice?.identifier
        UserDefaults.standard.set(map, forKey: storageKey)
    }

    static func chosenID(for language: String) -> String? { chosen[languageCode(language)] }

    /// The voice picked in Muisti's settings for this language; nil = the iPhone's own
    /// Spoken Content voice.
    static func chosenVoice(for language: String) -> AVSpeechSynthesisVoice? {
        chosenID(for: language).flatMap(AVSpeechSynthesisVoice.init(identifier:))
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Basic"
        }
    }

    private static var chosen: [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice, region: String) -> Int {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 30
        case .enhanced: quality = 20
        default: quality = 0
        }
        let sameRegion = voice.language.hasSuffix("-" + region) ? 5 : 0
        return quality + sameRegion
    }

    static func languageCode(_ tag: String) -> String {
        String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
}
