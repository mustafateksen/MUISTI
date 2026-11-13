import CoreGraphics
import CoreImage
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

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Bakes a clockwise turn into the pixels and re-encodes as JPEG. 0 returns the input.
    static func rotatedJPEG(_ data: Data, clockwiseDegrees: Int, quality: Double = 0.9) -> Data {
        let turn = ((clockwiseDegrees % 360) + 360) % 360
        guard turn != 0, let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return data }
        let orientation: CGImagePropertyOrientation
        switch turn {
        case 90: orientation = .right
        case 180: orientation = .down
        default: orientation = .left
        }
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return ciContext.jpegRepresentation(of: image.oriented(orientation), colorSpace: space, options: options) ?? data
    }

    /// Downsampled copy (long edge ≤ `maxPixel`), EXIF orientation applied. Decodes only what
    /// it needs, so a 12 MP still never sits fully decoded in memory.
    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG whose long edge is at most `maxPixel`; returns the input if it is already small.
    static func downscaledJPEG(_ data: Data, maxPixel: Int, quality: Double = 0.8) -> Data {
        let size = pixelSize(of: data)
        guard max(size.width, size.height) > CGFloat(maxPixel),
              let image = thumbnail(data, maxPixel: maxPixel),
              let jpeg = encodeJPEG(image, quality: quality)
        else { return data }
        return jpeg
    }
}
