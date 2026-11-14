import CoreGraphics
import Foundation
import os

/// The one place every picture passes before it leaves the phone (chat, tool calls, image
/// embeddings). It runs the same on-device private-scene check as capture (bathroom, shower,
/// a PIN pad…), so a frame that slipped past capture, or a live look taken in such a room,
/// never reaches the server. Fails closed: a picture that cannot be checked is not sent.
/// (Idea from the Android side's `Llm.imagePart` gate.)
enum OutgoingImageGate {
    /// Pictures already checked (hash of the bytes), so a frame sent twice is checked once.
    private static let cleared = OSAllocatedUnfairLock(initialState: [Int: Date]())

    static func allows(_ jpeg: Data) -> Bool {
        let key = jpeg.hashValue
        if cleared.withLock({ $0[key] }) != nil { return true }
        guard let image = ImageData.thumbnail(jpeg, maxPixel: 512) else {
            Log.net.error("outgoing image not sent: unreadable")
            return false
        }
        if PerceptionEngine.showsPrivateScene(image) {
            Log.net.info("outgoing image not sent: private scene")
            Trace.note("image withheld at the network: private scene")
            return false
        }
        cleared.withLock { map in
            if map.count > 400 { map.removeAll() }
            map[key] = Date()
        }
        return true
    }

    /// Checks several pictures at once (a time strip); keeps the order of those allowed.
    static func filter(_ images: [Data]) -> [Data] {
        var ok = [Bool](repeating: false, count: images.count)
        ok.withUnsafeMutableBufferPointer { flags in
            let flags = UnsafeMutableBufferPointer(start: flags.baseAddress, count: flags.count)
            DispatchQueue.concurrentPerform(iterations: images.count) { flags[$0] = allows(images[$0]) }
        }
        return zip(images, ok).filter(\.1).map(\.0)
    }
}
