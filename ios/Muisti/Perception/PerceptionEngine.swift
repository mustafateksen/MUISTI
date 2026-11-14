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

    func process(_ frame: CapturedFrame, street: String?) -> PerceptionResult {
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

    /// Full-frame read, then a second look at small text (Ömer's "zoom on text", v18: his
    /// glasses Q&A 29 → 30 of 31; far booth names are too few pixels for one 720p read).
    static func recognizeText(_ image: CGImage) -> [TextLine] {
        let full = read(image, minimumTextHeight: 0.012)
        let zoomed = zoomReads(image, full: full)
        return mergeZoomed(full: full, zoomed: zoomed)
            // Reading order: top to bottom, then left to right.
            .sorted { abs($0.box.midY - $1.box.midY) > 0.02 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }

    private static func read(_ image: CGImage, minimumTextHeight: Float) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        HeadBlur.prepare(request)
        request.recognitionLevel = .accurate
        // Off: language correction "fixes" phone digits and brand names (Ömer's Vision runs).
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        // Signs can be in any script (Finnish, English, Turkish, Chinese, Japanese…): let Vision
        // detect the language per frame; the preferred list only breaks ties.
        request.automaticallyDetectsLanguage = true
        let preferred = ["en-US", "fi-FI", "sv-SE", "tr-TR", "de-DE"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = preferred.filter { supported.contains($0) }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return TextLine(text: text, box: observation.boundingBox, confidence: best.confidence)
        }
    }

    /// Where text is (the detector finds text it cannot necessarily read), grouped into padded
    /// blocks; blocks with small text, or text the full read missed, are cropped, enlarged so a
    /// line is ~48 px (at most 4×) and read again. At most 8 blocks per frame.
    private static func zoomReads(_ image: CGImage, full: [TextLine]) -> [TextLine] {
        let detect = VNDetectTextRectanglesRequest()
        HeadBlur.prepare(detect)
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([detect]) } catch { return [] }
        let boxes = (detect.results ?? []).map(\.boundingBox).filter { $0.width > 0 && $0.height > 0 }
        guard !boxes.isEmpty else { return [] }
        let W = CGFloat(image.width), H = CGFloat(image.height)

        // Pad each box (a word or line is never cut in half), then merge touching ones.
        struct Block { var rect: CGRect; var lineHeight: CGFloat }
        var blocks: [Block] = boxes.map { b in
            Block(rect: b.insetBy(dx: -b.height, dy: -0.5 * b.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
                  lineHeight: b.height)
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in blocks.indices {
                for j in blocks.indices where j > i && blocks[i].rect.intersects(blocks[j].rect) {
                    blocks[i].rect = blocks[i].rect.union(blocks[j].rect)
                    blocks[i].lineHeight = min(blocks[i].lineHeight, blocks[j].lineHeight)
                    blocks.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }

        @Sendable func coveredByFull(_ rect: CGRect) -> Bool {
            full.contains { line in
                let overlap = line.box.intersection(rect)
                return !overlap.isNull && overlap.width * overlap.height >= 0.5 * line.box.width * line.box.height
            }
        }
        let candidates = blocks
            .filter { $0.lineHeight < 0.04 || !coveredByFull($0.rect) }
            .sorted { $0.lineHeight < $1.lineHeight }
            .prefix(8)

        // The crops are read side by side (they were read one after another: up to 8 Vision
        // passes in a row on every kept frame and on every live look).
        final class Reads: @unchecked Sendable {
            let lock = NSLock()
            var byBlock: [Int: [TextLine]] = [:]
        }
        let reads = Reads()
        let list = Array(candidates)
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            let block = list[index]
            var out: [TextLine] = []
            defer {
                reads.lock.lock()
                reads.byBlock[index] = out
                reads.lock.unlock()
            }
            let linePx = block.lineHeight * H
            let scale = min(4, max(1, 48 / max(linePx, 1)))
            guard scale >= 1.3 || !coveredByFull(block.rect) else { return }   // nothing to gain
            // Vision rects: origin bottom-left; CGImage crop: origin top-left.
            let pixel = CGRect(x: block.rect.minX * W, y: (1 - block.rect.maxY) * H,
                               width: block.rect.width * W, height: block.rect.height * H).integral
            guard pixel.width >= 8, pixel.height >= 8, let crop = image.cropping(to: pixel) else { return }
            let outW = Int(min(2400, pixel.width * scale)), outH = Int(min(2400, pixel.height * scale))
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            guard let big = ctx.makeImage() else { return }
            for line in read(big, minimumTextHeight: 0) {
                // Back to full-frame coordinates (both normalised, origin bottom-left).
                let b = line.box
                let mapped = CGRect(x: block.rect.minX + b.minX * block.rect.width,
                                    y: block.rect.minY + b.minY * block.rect.height,
                                    width: b.width * block.rect.width, height: b.height * block.rect.height)
                out.append(TextLine(text: line.text, box: mapped, confidence: line.confidence))
            }
        }
        return list.indices.flatMap { reads.byBlock[$0] ?? [] }
    }

    /// A zoomed reading replaces the full-frame readings it covers (≥ 80 % of their box) when
    /// Vision is more confident of it; a zoomed fragment of a longer full reading is dropped;
    /// text only the zoom found is added if read with confidence ≥ 0.5 (crops of things that
    /// only look like text gave junk such as "тизТиа)").
    static func mergeZoomed(full: [TextLine], zoomed: [TextLine]) -> [TextLine] {
        guard !zoomed.isEmpty else { return full }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        var kept = full
        var added: [TextLine] = []
        for z in zoomed {
            let overlapping = kept.filter { area($0.box.intersection(z.box)) > 0 }
            if overlapping.isEmpty {
                if z.confidence >= 0.5 { added.append(z) }
                continue
            }
            let covers = overlapping.allSatisfy { area($0.box.intersection(z.box)) >= 0.8 * area($0.box) }
            guard covers else { continue }   // a fragment of a longer line: keep the full reading
            // Only a better read replaces ("Floyds" must not become "Floyss").
            guard z.confidence > (overlapping.map(\.confidence).max() ?? 0) else { continue }
            kept.removeAll { f in overlapping.contains { $0.box == f.box && $0.text == f.text } }
            added.append(z)
        }
        // Zoomed lines overlapping each other (blocks may touch): keep the longer text.
        var result = kept
        for z in added.sorted(by: { $0.text.count > $1.text.count })
            where !result.contains(where: { area($0.box.intersection(z.box)) >= 0.5 * area(z.box) }) {
            result.append(z)
        }
        return result
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
