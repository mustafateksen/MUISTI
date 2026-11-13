import Foundation

/// Contract with Kişi 2 (perception line). Kişi 2 implements this with filtering,
/// Vision OCR, face/plate blurring and street lookup, then swaps it in
/// `CaptureController.sink`.
protocol FrameSink: Sendable {
    /// Returns the enriched payload if the frame is kept, `nil` if dropped.
    func process(_ frame: CapturedFrame) async -> IngestPayload?
}

/// `/ingest` body. Field names are the wire contract with Kişi 3 — do not rename.
struct IngestPayload: Codable, Sendable {
    let seen_at: String            // ISO 8601, UTC
    let lat: Double?
    let lon: Double?
    let heading: Double?
    let street: String?
    let ocr_text: String
    let frame_jpeg_b64: String

    init(frame: CapturedFrame, ocrText: String = "", street: String? = nil, jpeg: Data? = nil) {
        seen_at = ISO8601.string(from: frame.capturedAt)
        lat = frame.latitude
        lon = frame.longitude
        heading = frame.headingDegrees
        self.street = street
        ocr_text = ocrText
        frame_jpeg_b64 = (jpeg ?? frame.jpeg).base64EncodedString()
    }
}

enum ISO8601 {
    // Guarded by `lock`.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let lock = NSLock()

    static func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// Until Kişi 2 is ready: stills (adaptive/interval/photo) always pass; stream frames pass
/// one in every N. `ocr_text` stays empty.
actor PassthroughSink: FrameSink {
    private let everyN: Int
    private var streamCounter = 0

    init(everyN: Int) { self.everyN = max(1, everyN) }

    func process(_ frame: CapturedFrame) async -> IngestPayload? {
        if frame.trigger == .stream {
            streamCounter += 1
            guard streamCounter % everyN == 0 else { return nil }
        }
        return IngestPayload(frame: frame)
    }
}
