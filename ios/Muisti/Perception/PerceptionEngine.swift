import Accelerate
import CoreImage
import CoreLocation
import Foundation
import ImageIO
import Vision

/// A place where nothing is recorded (home, work…). Plan: "kayıt yok" bölgeleri.
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
        case .blurry: return "bulanık"
        case .duplicate: return "tekrar"
        case .noRecordZone: return "kayıt dışı bölge"
        case .noText: return "yazısız"
        case .unreadable: return "okunamadı"
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
        var keyframeMaxPixel = 1280
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
        _ = detectFaces(image)
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

        // OCR on a ~2400 px copy (12 MP is slower and not more legible for Vision).
        let lines = Self.recognizeText(ocrImage)
        let plates = lines.filter { Self.looksLikePlate($0.text) }
        let textLines = lines.filter { !Self.looksLikePlate($0.text) }
        let ocrText = textLines.map(\.text).joined(separator: "\n")

        if frame.trigger != .manual {
            // Same view (image hash) with the same text, or the same sign read again while it
            // slides across the frame (text overlap) — unless this read is clearly more complete.
            for (index, recent) in recentHashes.enumerated() {
                let imageClose = (recent.hash ^ hash).nonzeroBitCount <= tuning.duplicateHamming
                if imageClose && Self.sameText(recent.text, ocrText) { return .drop(.duplicate) }
                guard !ocrText.isEmpty, !recent.text.isEmpty,
                      Self.tokenOverlap(recent.text, ocrText) >= 0.5 else { continue }
                let moreComplete = ocrText.count >= recent.text.count + 3
                    && Double(ocrText.count) >= Double(recent.text.count) * 1.05
                if !moreComplete { return .drop(.duplicate) }
                // Same sign, read better now: keep this one and retire the partial read.
                replaces = recent.memoryId
                recentHashes.remove(at: index)
                break
            }
            if ocrText.isEmpty {
                if let last = lastTextlessKeep, frame.capturedAt.timeIntervalSince(last) < tuning.keepTextlessEvery {
                    return .drop(.noText)
                }
                lastTextlessKeep = frame.capturedAt
            }
        }
        recentHashes.append((hash, frame.capturedAt, ocrText, nil))

        // Privacy: blur faces and plates before anything is stored or sent.
        let faces = Self.detectFaces(ocrImage)
        let regions = faces + plates.map(\.box)
        guard let keyframe = blurredKeyframe(ocrImage, regions: regions) else { return .drop(.unreadable) }

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

    struct TextLine: Sendable {
        let text: String
        let box: CGRect   // normalised, Vision coordinates (origin bottom-left)
        let confidence: Float
    }

    static func recognizeText(_ image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012
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

    static func detectFaces(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Downsizes to keyframe size first, then pixellates only the (padded) face/plate regions
    /// and composites them back. Whole-image filters on a 2400 px frame took seconds.
    private func blurredKeyframe(_ image: CGImage, regions: [CGRect]) -> Data? {
        var base = CIImage(cgImage: image)
        let longEdge = max(base.extent.width, base.extent.height)
        let factor = min(1, CGFloat(tuning.keyframeMaxPixel) / longEdge)
        if factor < 1 {
            base = base.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        let extent = base.extent
        var output = base
        for r in regions {
            let rect = CGRect(x: extent.minX + r.minX * extent.width, y: extent.minY + r.minY * extent.height,
                              width: r.width * extent.width, height: r.height * extent.height)
                .insetBy(dx: -r.width * extent.width * 0.25, dy: -r.height * extent.height * 0.25)
                .intersection(extent)
            guard !rect.isEmpty else { continue }
            let block = max(8, max(rect.width, rect.height) / 8)
            let patch = base.cropped(to: rect).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block,
                                                            kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
                .applyingGaussianBlur(sigma: block / 3)
                .cropped(to: rect)
            output = patch.composited(over: output)
        }
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
