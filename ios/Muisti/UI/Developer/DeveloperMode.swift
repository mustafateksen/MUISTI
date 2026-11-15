import Foundation

/// Developer options (capture modes, Nemotron endpoint, scheduler tuning, mock glasses,
/// live diagnostics) are hidden from end users until this switch is on in Settings.
enum DeveloperMode {
    static let storageKey = "developerMode"
    /// Timings, traces and other developer lines are hidden even with developer options on
    /// (set while the remote driver runs: the screen is being recorded).
    static let cleanScreenKey = "demo.cleanScreen"
    /// The status island as the remote driver staged it: "recording" or "off" (absent: the real one).
    static let stageStatusKey = "demo.stageStatus"
    static let stageBatteryKey = "demo.stageBattery"
}
