@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// One stretch of glasses video recorded while Muisti was in the background.
struct BackgroundSegment: Sendable {
    let url: URL
    /// Wall-clock time of the first frame.
    let startedAt: Date
    let duration: TimeInterval
}

/// Background capture. The Meta SDK keeps an `.hvc1` (HEVC) stream running when the app is in
/// the background, but iOS gives a background app no GPU / hardware video decoder. So nothing
/// is decoded here: the compressed samples are written straight into an MP4 (passthrough, no
/// re-encoding, no GPU). When Muisti is back in the foreground the controller samples the file
/// and runs those frames through the normal pipeline (OCR, masking, dedup, episodes,
/// Nemotron) with their real times and locations; the file is then deleted.
final class BackgroundSegmentRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fi.junction.muisti.bgsegment")
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var startedAt: Date?
    private var failed = false

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("bg-\(UUID().uuidString).mp4")
    }

    /// Called from the SDK's frame callback (any thread). Drops frames until the first sync
    /// (key) frame so the file starts decodable.
    func append(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !failed, CMSampleBufferDataIsReady(sample) else { return }
            if writer == nil {
                guard Self.isSync(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { failed = true; return }
                    writer.add(input)
                    guard writer.startWriting() else { failed = true; return }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    writer.startSession(atSourceTime: pts)
                    self.writer = writer
                    self.input = input
                    firstPTS = pts
                    startedAt = Date()
                } catch {
                    failed = true
                    Log.glasses.error("background segment: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            guard let input, input.isReadyForMoreMediaData else { return }
            if input.append(sample) {
                lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            }
        }
    }

    /// Closes the file. nil when nothing usable was recorded (the file is removed then).
    func finish() async -> BackgroundSegment? {
        await withCheckedContinuation { (done: CheckedContinuation<BackgroundSegment?, Never>) in
            queue.async { [self] in
                guard let writer, let input, let firstPTS, let startedAt, writer.status == .writing else {
                    try? FileManager.default.removeItem(at: url)
                    done.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                let duration = (lastPTS ?? firstPTS) - firstPTS
                let url = url
                writer.finishWriting {
                    guard writer.status == .completed, duration.seconds > 0.5 else {
                        try? FileManager.default.removeItem(at: url)
                        done.resume(returning: nil)
                        return
                    }
                    done.resume(returning: BackgroundSegment(url: url, startedAt: startedAt, duration: duration.seconds))
                }
            }
        }
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
