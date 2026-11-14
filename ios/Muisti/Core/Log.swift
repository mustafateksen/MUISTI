import Foundation
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

/// A small trace file next to the app's caches (`Library/Caches/muisti-trace.log`) for
/// field tests without a cable: background / lock-screen behaviour can be read afterwards
/// (`devicectl device copy from`). Capped at ~1 MB (older half dropped).
enum Trace {
    private static let queue = DispatchQueue(label: "fi.junction.muisti.trace")
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("muisti-trace.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Set by the glasses source on background / foreground transitions.
    nonisolated(unsafe) static var inBackground = false

    static func note(_ text: String) {
        let line = "\(formatter.string(from: Date())) [\(inBackground ? "bg" : "fg")] \(text)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if let size = try? handle.seekToEnd(), size > 1_000_000 {
                    try? handle.close()
                    if let old = try? Data(contentsOf: url) { try? old.suffix(old.count / 2).write(to: url) }
                    if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
