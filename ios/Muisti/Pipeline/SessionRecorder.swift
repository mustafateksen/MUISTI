import Foundation

/// Writes a dataset to disk so the 3-hour glasses window can be replayed later.
///
/// ```
/// Documents/sessions/2026-11-13T21-04-05Z/
///   frames/000001.jpg
///   meta.jsonl   {"i","t","origin","trigger","w","h","lat","lon","acc","heading","speed","highRes"}
///   gps.jsonl    {"t","lat","lon","acc","speed","course"}   every accepted fix
/// ```
/// Visible in the Files app (UIFileSharingEnabled), AirDrop to the Mac from there.
actor SessionRecorder {
    private var directory: URL?
    private var framesDir: URL?
    private var metaHandle: FileHandle?
    private var gpsHandle: FileHandle?
    private var index = 0
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static var sessionsRoot: URL {
        get throws {
            try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
    }

    var currentDirectory: URL? { directory }
    var frameCount: Int { index }

    @discardableResult
    func begin() throws -> URL {
        finish()
        let name = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = try Self.sessionsRoot.appendingPathComponent(name, isDirectory: true)
        let frames = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let meta = dir.appendingPathComponent("meta.jsonl")
        let gps = dir.appendingPathComponent("gps.jsonl")
        FileManager.default.createFile(atPath: meta.path, contents: nil)
        FileManager.default.createFile(atPath: gps.path, contents: nil)
        metaHandle = try FileHandle(forWritingTo: meta)
        gpsHandle = try FileHandle(forWritingTo: gps)
        directory = dir
        framesDir = frames
        index = 0
        Log.pipeline.info("recording to \(dir.lastPathComponent, privacy: .public)")
        return dir
    }

    func write(_ frame: CapturedFrame) {
        guard let framesDir, let metaHandle else { return }
        index += 1
        let file = framesDir.appendingPathComponent(String(format: "%06d.jpg", index))
        do {
            try frame.jpeg.write(to: file, options: .atomic)
            let line = FrameMeta(
                i: index,
                t: ISO8601.string(from: frame.capturedAt),
                origin: frame.origin.rawValue,
                trigger: frame.trigger.rawValue,
                w: Int(frame.pixelSize.width),
                h: Int(frame.pixelSize.height),
                lat: frame.latitude,
                lon: frame.longitude,
                acc: frame.horizontalAccuracy,
                heading: frame.headingDegrees,
                speed: frame.speedMps,
                highRes: frame.isHighRes
            )
            try metaHandle.write(contentsOf: encoder.encode(line) + Data([0x0A]))
        } catch {
            Log.pipeline.error("recorder write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func record(_ fix: LocationFix) {
        guard let gpsHandle else { return }
        let line = GPSLine(
            t: ISO8601.string(from: fix.timestamp),
            lat: fix.latitude,
            lon: fix.longitude,
            acc: fix.accuracy,
            speed: fix.validSpeed,
            course: fix.course >= 0 ? fix.course : nil
        )
        try? gpsHandle.write(contentsOf: encoder.encode(line) + Data([0x0A]))
    }

    func finish() {
        try? metaHandle?.close()
        try? gpsHandle?.close()
        metaHandle = nil
        gpsHandle = nil
        framesDir = nil
        directory = nil
    }

    private struct FrameMeta: Encodable {
        let i: Int
        let t: String
        let origin: String
        let trigger: String
        let w: Int
        let h: Int
        let lat: Double?
        let lon: Double?
        let acc: Double?
        let heading: Double?
        let speed: Double?
        let highRes: Bool
    }

    private struct GPSLine: Encodable {
        let t: String
        let lat: Double
        let lon: Double
        let acc: Double
        let speed: Double?
        let course: Double?
    }
}
