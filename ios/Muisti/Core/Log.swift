import os

/// Thin wrapper over `os.Logger`. Filter in Console.app with subsystem `fi.junction.muisti`.
enum Log {
    private static let subsystem = "fi.junction.muisti"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let glasses = Logger(subsystem: subsystem, category: "glasses")
    static let phone = Logger(subsystem: subsystem, category: "phone")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    static let motion = Logger(subsystem: subsystem, category: "motion")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let mock = Logger(subsystem: subsystem, category: "mock")
}
