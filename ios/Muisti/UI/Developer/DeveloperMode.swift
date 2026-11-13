import Foundation

/// Developer options (capture modes, Nemotron endpoint, scheduler tuning, mock glasses,
/// live diagnostics) are hidden from end users until this switch is on in Settings.
enum DeveloperMode {
    static let storageKey = "developerMode"
}
