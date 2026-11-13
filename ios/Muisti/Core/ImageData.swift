import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small ImageIO helpers that never fully decode an image.
enum ImageData {
    /// Pixel size from the header only.
    static func pixelSize(of data: Data) -> CGSize {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return .zero }
        // EXIF orientations 5–8 are rotated 90°.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// Returns JPEG bytes; transcodes HEIC/PNG if needed.
    static func ensureJPEG(_ data: Data, quality: Double = 0.85) -> Data? {
        if isJPEG(data) { return data }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
