import CoreGraphics
import ImageIO
import CoreMedia
import Foundation
import os
import VideoToolbox

/// Decodes the glasses' `.hvc1` stream in the foreground (hardware decoder, ~nothing on the
/// CPU) and keeps the newest picture. Why not the `.raw` stream: the SDK pauses `.raw` in the
/// background, so going to the lock screen meant tearing the camera down and starting an
/// `.hvc1` one. That released the glasses' Wi-Fi link, and a locked iPhone cannot join the
/// glasses' network again ("Timed out waiting for IP address"). One `.hvc1` stream for both
/// keeps the link: in the background its samples are only written to a file (iOS gives a
/// background app no hardware decoder), in the foreground they are decoded here.
/// A decoded picture (pixel buffers are immutable once decoded).
struct DecodedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let at: Date
}

final class HEVCFrameDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fi.junction.muisti.hevc")
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var needsSync = true
    private var errors = 0
    private let latest = OSAllocatedUnfairLock<DecodedFrame?>(initialState: nil)
    private let decodedCount = OSAllocatedUnfairLock(initialState: 0)

    /// Frames decoded since the last `reset()`.
    var decoded: Int { decodedCount.withLock { $0 } }

    /// From the SDK's frame callback (any thread).
    func decode(_ sample: CMSampleBuffer) {
        queue.async { [self] in decodeOnQueue(sample) }
    }

    /// Back from the background (the decoder session is gone) or a new stream: start again at
    /// the next key frame.
    func reset() {
        queue.async { [self] in
            dropSession()
            decodedCount.withLock { $0 = 0 }
        }
        latest.withLock { $0 = nil }
    }

    /// The newest picture if it is younger than `maxAge`; `take` clears it (the next scheduled
    /// still must be a new frame).
    func newest(maxAge: TimeInterval, take: Bool) -> DecodedFrame? {
        latest.withLock { value in
            guard let v = value, Date().timeIntervalSince(v.at) < maxAge else { return nil }
            if take { value = nil }
            return v
        }
    }

    /// JPEG on the CPU (CoreGraphics + ImageIO): a background app may not use the GPU, which
    /// Core Image would.
    static func jpeg(_ buffer: CVPixelBuffer, quality: CGFloat) -> (Data, CGSize)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, CGSize(width: width, height: height))
    }

    private func decodeOnQueue(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        if let format, !CMFormatDescriptionEqual(format, otherFormatDescription: desc) { dropSession() }
        if needsSync {
            guard Self.isSync(sample) else { return }
        }
        if session == nil {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var newSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                      imageBufferAttributes: attributes as CFDictionary,
                                                      outputCallback: nil, decompressionSessionOut: &newSession)
            guard status == noErr, let newSession else {
                Log.glasses.info("HEVC decoder not created: \(status)")
                Trace.note("HEVC decoder not created: \(status)")
                return
            }
            session = newSession
            format = desc
        }
        needsSync = false
        guard let session else { return }
        let latest = latest, count = decodedCount
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            let frame = DecodedFrame(buffer: image, at: Date())
            latest.withLock { $0 = frame }
            count.withLock { $0 += 1 }
        }
        if status != noErr {
            // Typically after the app was in the background: build a new session at the next key frame.
            errors += 1
            if errors <= 3 || errors % 50 == 0 {
                Log.glasses.info("HEVC decode error \(status) (\(self.errors) so far)")
                Trace.note("HEVC decode error \(status) (\(errors) so far)")
            }
            dropSession()
        }
    }

    private func dropSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        needsSync = true
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
