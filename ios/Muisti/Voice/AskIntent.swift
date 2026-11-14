import AppIntents
import Observation

/// Hands-free trigger: "Hey Siri, ask Muisti" or the iPhone Action Button / Shortcuts.
/// Opens the app (the glasses session needs the foreground) and starts listening.
struct AskMuistiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Muisti"
    static let description = IntentDescription("Asks a spoken question about what your glasses have seen.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppSignals.shared.requestListening()
        return .result()
    }
}

struct MuistiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskMuistiIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Question for \(.applicationName)",
            ],
            shortTitle: "Ask Muisti",
            systemImageName: "mic.fill"
        )
    }
}

/// Cross-cutting signals from intents / URLs to the UI.
@Observable
@MainActor
final class AppSignals {
    static let shared = AppSignals()
    /// Set by the intent (possibly before any view exists on a cold launch); consumed by the UI.
    private(set) var pendingListen = false

    func requestListening() { pendingListen = true }

    func consumeListenRequest() -> Bool {
        defer { pendingListen = false }
        return pendingListen
    }
}
