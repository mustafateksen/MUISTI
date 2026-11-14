import Foundation
import Speech

/// Which language the question recogniser listens for: English (US) by default, or one picked
/// in Settings. "Automatic" (the phone's first supported language) is only a choice, never the
/// default: a wrong-language recogniser turns speech into nonsense. Answers are spoken in the language
/// detected in the question, whatever this is.
enum SpeechLanguage {
    static let automatic = "auto"
    static let fallback = "en-US"

    /// The recogniser locale identifier for a saved choice.
    static func resolve(_ choice: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
        if choice != automatic {
            return supported.contains(choice) ? choice : fallback
        }
        for preferred in Locale.preferredLanguages {
            let id = preferred.replacingOccurrences(of: "_", with: "-")
            if supported.contains(id) { return id }
            let language = Locale(identifier: id).language.languageCode?.identifier
            let region = Locale(identifier: id).region?.identifier
            let sameLanguage = supported.filter { Locale(identifier: $0).language.languageCode?.identifier == language }
            // Same region if the recogniser has it ("en-GB"); else the language's main locale
            // ("en-US", "tr-TR", "fi-FI"). Never the alphabetical first: an English phone in
            // Turkey ("en-TR") used to get the en-AE recogniser.
            let main = language == "en" ? "en-US" : language.map { "\($0)-\($0.uppercased())" }
            if let match = sameLanguage.first(where: { Locale(identifier: $0).region?.identifier == region })
                ?? sameLanguage.first(where: { $0 == main })
                ?? sameLanguage.sorted().first {
                return match
            }
        }
        return fallback
    }

    /// Every language the recogniser supports, sorted by its name in the app's language.
    static var choices: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
            .map { (id: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
