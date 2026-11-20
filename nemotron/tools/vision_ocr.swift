// MUISTI - Apple Vision OCR for a folder of frames (macOS command line).
//
// Usage (on a Mac):
//   swift vision_ocr.swift <frames_folder> > ocr.json
//
// Output: { "f00585.jpg": [ {"text": "...", "conf": 0.98, "box": [x, y, w, h]}, ... ], ... }
// box is normalized 0..1 with origin TOP-left (converted from Vision's bottom-left).
//
// Use the SAME settings in the iPhone app so offline tests match the real pipeline.

import Foundation
import Vision
import AppKit

func ocr(_ url: URL) -> [[String: Any]] {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate          // fast mode misses small sign text
    request.usesLanguageCorrection = false        // correction "fixes" phone digits and brand names
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.015             // default (~1/32 of height) skips small text on 720p

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([request])

    var out: [[String: Any]] = []
    for obs in request.results ?? [] {
        guard let top = obs.topCandidates(1).first else { continue }
        let b = obs.boundingBox
        out.append([
            "text": top.string,
            "conf": Double(top.confidence),
            "box": [Double(b.minX), Double(1 - b.maxY), Double(b.width), Double(b.height)],
        ])
    }
    return out
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try FileManager.default.contentsOfDirectory(atPath: folder.path))
    .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".png") }
    .sorted()

var result: [String: Any] = [:]
for f in files {
    result[f] = ocr(folder.appendingPathComponent(f))
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
