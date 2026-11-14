import CoreImage
import Foundation
import Vision

/// The local gates and the privacy copy of a frame for Muisti Turva, all on the phone:
/// hands in view (Vision hand pose), OCR text, and the frame with heads and plates masked —
/// the only version that may be sent to Nemotron or kept as evidence.
enum SafetyFrame {
    struct Prepared: Sendable {
        let jpeg: Data
        let ocr: String
        let lineCount: Int
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Wearer's hands in view (cheap: 512 px, hand pose only).
    static func handsVisible(_ jpeg: Data) -> Bool {
        guard let image = ImageData.thumbnail(jpeg, maxPixel: 512) else { return false }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        HeadBlur.prepare(request)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return !(request.results ?? []).filter { $0.confidence > 0.3 }.isEmpty
    }

    /// OCR + head masking at `maxPixel`. nil when head detection failed (fail-safe: nothing
    /// unmasked leaves the phone).
    static func prepare(_ jpeg: Data, maxPixel: Int = 1280) -> Prepared? {
        guard let image = ImageData.thumbnail(jpeg, maxPixel: maxPixel) else { return nil }
        let analysis = PerceptionEngine.textAndHeads(image)
        guard let heads = analysis.heads else { return nil }
        let plates = analysis.lines.filter { PerceptionEngine.looksLikePlate($0.text) }
        let text = analysis.lines.filter { !PerceptionEngine.looksLikePlate($0.text) }
        let base = CIImage(cgImage: image)
        let masked = HeadBlur.mask(base, heads: heads, plates: plates.map(\.box))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
        guard let out = context.jpegRepresentation(of: masked.cropped(to: base.extent), colorSpace: space, options: options) else { return nil }
        let rows = PerceptionEngine.visualRows(text)
        return Prepared(jpeg: out, ocr: rows.joined(separator: "\n"), lineCount: rows.count)
    }
}
