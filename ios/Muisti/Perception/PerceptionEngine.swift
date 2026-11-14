import Accelerate
import CoreImage
import CoreLocation
import Foundation
import ImageIO
import Vision

/// A place where nothing is recorded (home, work…). Plan: "no-record" zones.
struct NoRecordZone: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 100

    func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        MemoryStore.haversine(latitude, longitude, lat, lon) <= radius
    }
}

enum DropReason: String, Sendable, CaseIterable {
    case blurry, duplicate, noRecordZone, noText, unreadable

    var label: String {
        switch self {
        case .blurry: return "blurry"
        case .duplicate: return "duplicate"
        case .noRecordZone: return "no-record zone"
        case .noText: return "no text"
        case .unreadable: return "unreadable"
        }
    }
}

enum PerceptionResult: Sendable {
    /// `replaces`: an earlier, less complete read of the same sign to delete.
    case keep(NewMemory, sharpness: Double, replaces: Int64?)
    case drop(DropReason)
}

/// Everything that happens to a frame before it is remembered, all on the phone:
/// 1. no-record zone check, 2. sharpness (variance of Laplacian), 3. near-duplicate (dHash),
/// 4. Apple Vision OCR, 5. face + licence-plate blurring, 6. small blurred keyframe.
/// The raw frame is never stored here.
actor PerceptionEngine {
    struct Tuning: Sendable {
        var minSharpness: Double = 60            // Laplacian variance on a 512 px grey image
        var duplicateHamming = 6                 // dHash bits; lower = more similar
        var duplicateWindow: TimeInterval = 45
        var keepTextlessEvery: TimeInterval = 60 // keep one scene frame per minute even without text
        var keyframeMaxPixel = 1536   // team measurement: 1536 px long side for Nemotron
        var ocrMaxPixel = 2400
    }

    var tuning = Tuning()
    var zones: [NoRecordZone] = []
    private var recentHashes: [(hash: UInt64, at: Date, text: String, memoryId: Int64?)] = []
    private var lastTextlessKeep: Date?
    private var lastPanelRetry: (hash: UInt64, at: Date)?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func configure(zones: [NoRecordZone]) { self.zones = zones }

    /// Loads the Vision text/face models once (first use takes seconds; it is process-wide).
    /// Static and actor-free on purpose: warming up must never block the perception actor.
    static func warmUpModels() {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage()
        else { return }
        _ = recognizeText(image)
        _ = HeadBlur.heads(in: image)
    }

    func analyze(_ frame: CapturedFrame, street: String?, checkPeanut: Bool) -> (PerceptionResult, PeanutLabel?) {
        var alert: PeanutLabel?
        let result = process(frame, street: street, checkPeanut: checkPeanut, alert: &alert)
        return (result, alert)
    }

    private func process(_ frame: CapturedFrame, street: String?, checkPeanut: Bool, alert: inout PeanutLabel?) -> PerceptionResult {
        if let lat = frame.latitude, let lon = frame.longitude, zones.contains(where: { $0.contains(latitude: lat, longitude: lon) }) {
            return .drop(.noRecordZone)
        }
        guard let analysis = ImageData.thumbnail(frame.jpeg, maxPixel: 512),
              let ocrImage = ImageData.thumbnail(frame.jpeg, maxPixel: tuning.ocrMaxPixel)
        else { return .drop(.unreadable) }

        // Sharpness first: cheapest way to drop motion-blurred frames.
        let sharpness = Self.laplacianVariance(analysis)
        // Near-uniform (covered lens, pocket, darkness): useless even when taken by hand.
        if sharpness < 4 { return .drop(.unreadable) }
        if sharpness < tuning.minSharpness, frame.trigger != .manual {
            return .drop(.blurry)
        }

        let hash = Self.dHash(analysis)
        var replaces: Int64?
        recentHashes.removeAll { frame.capturedAt.timeIntervalSince($0.at) > tuning.duplicateWindow }

        // OCR and head detection in parallel on the same ~2400 px copy (12 MP is slower and not
        // more legible for Vision). Heads are only used if the frame is kept below.
        let parallel = Self.textAndHeads(ocrImage)
        let lines = parallel.lines
        let plates = lines.filter { Self.looksLikePlate($0.text) }
        let textLines = lines.filter { !Self.looksLikePlate($0.text) }
        let ocrText = Self.visualRows(textLines).joined(separator: "\n")

        if checkPeanut {
            var labelLines = textLines
            // A missed target word cannot trigger a line crop. Independently retry a
            // recognizable ingredients panel once per similar view in a short burst.
            let panel = labelLines.contains { PeanutLabel.panel($0.text) }
            let mention = labelLines.contains { PeanutLabel.mentions($0.text) }
            let recentRetry = lastPanelRetry.map {
                (0..<20).contains(frame.capturedAt.timeIntervalSince($0.at)) && ($0.hash ^ hash).nonzeroBitCount <= 6
            } ?? false
            if panel && !mention && !recentRetry {
                lastPanelRetry = (hash,frame.capturedAt)
                let fine = Self.recognizeText(ocrImage, correction:false, minHeight:0.006)
                // Keep indications visible only on the retry as unconfirmed mentions.
                // Avoid switching context or treating a retry-only word as a declaration.
                labelLines += fine.filter { PeanutLabel.mentions($0.text) }.map {
                    TextLine(text:$0.text,box:$0.box,confidence:min($0.confidence,0.64))
                }
            }
            alert = PeanutLabel.evaluate(labelLines, hash: hash, frame: frame) { i in
                Self.reread(labelLines[i], in: ocrImage)
            }
        }
        let manual = frame.trigger == .manual
        // Same view (image hash) with the same text, or the same sign read again while it
        // slides across the frame (text overlap) — unless this read is clearly more complete.
        // A frame taken by hand is never dropped, but it still retires an earlier partial read.
        for (index, recent) in recentHashes.enumerated() {
            let imageClose = (recent.hash ^ hash).nonzeroBitCount <= tuning.duplicateHamming
            if imageClose && Self.sameText(recent.text, ocrText) {
                if manual { continue }
                return .drop(.duplicate)
            }
            guard !ocrText.isEmpty, !recent.text.isEmpty,
                  Self.tokenOverlap(recent.text, ocrText) >= 0.5 else { continue }
            let moreComplete = ocrText.count >= recent.text.count + 3
                && Double(ocrText.count) >= Double(recent.text.count) * 1.05
            if !moreComplete {
                if manual { continue }
                return .drop(.duplicate)
            }
            // Same sign, read better now: keep this one and retire the partial read.
            replaces = recent.memoryId
            recentHashes.remove(at: index)
            break
        }
        if !manual {
            if ocrText.isEmpty {
                if let last = lastTextlessKeep, frame.capturedAt.timeIntervalSince(last) < tuning.keepTextlessEvery {
                    return .drop(.noText)
                }
                lastTextlessKeep = frame.capturedAt
            }
        }
        recentHashes.append((hash, frame.capturedAt, ocrText, nil))

        // Privacy: mask heads and plates before anything is stored or sent. If head detection
        // fails, the frame is dropped (fail-safe), never kept unmasked.
        guard let heads = parallel.heads,
              let keyframe = blurredKeyframe(ocrImage, heads: heads, plates: plates.map(\.box))
        else { return .drop(.unreadable) }

        let memory = NewMemory(
            seenAt: frame.capturedAt,
            latitude: frame.latitude,
            longitude: frame.longitude,
            accuracy: frame.horizontalAccuracy,
            heading: frame.headingDegrees,
            street: street,
            ocrText: ocrText,
            frameJPEG: keyframe
        )
        return .keep(memory, sharpness: sharpness, replaces: replaces)
    }

    /// Links a stored memory to its recent-frame entry so a better read can replace it.
    func didStore(id: Int64, capturedAt: Date) {
        if let index = recentHashes.lastIndex(where: { $0.at == capturedAt }) {
            recentHashes[index].memoryId = id
        }
    }

    // MARK: OCR

    /// Text recognition and head detection at the same time (two cores / Neural Engine).
    static func textAndHeads(_ image: CGImage) -> (lines: [TextLine], heads: [CGRect]?) {
        final class Box: @unchecked Sendable {
            var lines: [TextLine] = []
            var heads: [CGRect]?
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 { box.lines = recognizeText(image) } else { box.heads = HeadBlur.heads(in: image) }
        }
        return (box.lines, box.heads)
    }

    struct TextLine: Sendable {
        let text: String
        let box: CGRect   // normalised, Vision coordinates (origin bottom-left)
        let confidence: Float
    }

    static func reread(_ line: TextLine, in image: CGImage) -> TextLine? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let b = line.box
        let rect = CGRect(x:b.minX*w, y:(1-b.maxY)*h, width:b.width*w, height:b.height*h)
            .insetBy(dx:-4,dy:-3).integral
        guard let crop = image.cropping(to:rect.intersection(CGRect(x:0,y:0,width:w,height:h))) else { return nil }
        let parts = recognizeText(crop, correction:false)
        guard let anchor = parts.first, parts.allSatisfy({
            abs($0.box.midY - anchor.box.midY) <= 0.45 * min($0.box.height,anchor.box.height)
        }), let confidence = parts.map(\.confidence).min() else { return nil }
        let quote = parts.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator:" ")
        return TextLine(text:quote,box:b,confidence:confidence)
    }

    static func recognizeText(_ image: CGImage, correction: Bool = true, minHeight: Float = 0.012) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        HeadBlur.prepare(request)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correction
        request.minimumTextHeight = minHeight
        let wanted = ["fi-FI", "sv-SE", "en-US", "tr-TR", "de-DE"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = wanted.filter { supported.contains($0) }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return TextLine(text: text, box: observation.boundingBox, confidence: best.confidence)
        }
        // Reading order: top to bottom, then left to right.
        .sorted { abs($0.box.midY - $1.box.midY) > 0.02 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }

    /// One string per visual row, top to bottom; boxes on the same row are joined left to right,
    /// so a label and its value side by side ("5TH FLOOR  ARDUINO LAB") stay on one line.
    /// Vision boxes are normalised with the origin at the bottom left.
    static func visualRows(_ lines: [TextLine]) -> [String] {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            // Same row: vertical centres closer than half the smaller box height.
            if let i = rows.firstIndex(where: { row in
                row.contains { abs($0.box.midY - line.box.midY) < 0.5 * min($0.box.height, line.box.height) }
            }) {
                rows[i].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
    }

    /// Finnish / EU style plates: "ABC-123", "AB-1234", "ABC 123". Never stored as text.
    static func looksLikePlate(_ text: String) -> Bool {
        let t = text.uppercased().trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^[A-ZÅÄÖ]{2,3}[- ]?[0-9]{1,4}$"#, options: .regularExpression) != nil
    }

    /// Share of the smaller token set found in the larger one (0…1). Tokens of ≥ 3 characters;
    /// single digits ("2", "9") would match everything and merge different signs.
    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(EvidenceRule.normalized(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count >= 3 })
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let (small, large) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        // Partial reads ("AHVILA" vs "KAHVILA") still count, for tokens long enough to be specific.
        let hits = small.filter { t in
            large.contains { $0 == t || (min($0.count, t.count) >= 4 && ($0.contains(t) || t.contains($0))) }
        }.count
        return Double(hits) / Double(small.count)
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        let na = EvidenceRule.normalized(a), nb = EvidenceRule.normalized(b)
        if na.isEmpty || nb.isEmpty { return na.isEmpty && nb.isEmpty }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    // MARK: Privacy

    /// Downsizes to keyframe size first, then masks heads and plates on that small copy
    /// (masking at OCR size took seconds; at 1280 px it is a few milliseconds on the GPU).
    private func blurredKeyframe(_ image: CGImage, heads: [CGRect], plates: [CGRect]) -> Data? {
        var base = CIImage(cgImage: image)
        let longEdge = max(base.extent.width, base.extent.height)
        let factor = min(1, CGFloat(tuning.keyframeMaxPixel) / longEdge)
        if factor < 1 {
            base = base.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        let extent = base.extent
        let output = HeadBlur.mask(base, heads: heads, plates: plates)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.78]
        return context.jpegRepresentation(of: output.cropped(to: extent), colorSpace: space, options: options)
    }

    // MARK: Quality

    /// Variance of the Laplacian on an 8-bit grey copy: low = blurry.
    static func laplacianVariance(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return 0 }
        var grey = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &grey, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let lap = Double(grey[i - width]) + Double(grey[i + width]) + Double(grey[i - 1]) + Double(grey[i + 1]) - 4 * Double(grey[i])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// 64-bit difference hash on a 9×8 grey thumbnail.
    static func dHash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &pixels, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }
}
