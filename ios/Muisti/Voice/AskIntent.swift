import AppIntents
import Observation

/// Hands-free trigger: "Hey Siri, Muisti'ye sor" or the iPhone Action Button / Shortcuts.
/// Opens the app (the glasses session needs the foreground) and starts listening.
struct AskMuistiIntent: AppIntent {
    static let title: LocalizedStringResource = "Muisti'ye sor"
    static let description = IntentDescription("Gözlüğün gördüklerine dair sesli soru sorar.")
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
                "\(.applicationName)'ye sor",
                "\(.applicationName)'e sor",
                "Ask \(.applicationName)",
            ],
            shortTitle: "Muisti'ye sor",
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
