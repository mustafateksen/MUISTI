// MUISTI - Apple Vision OCR with "zoom on text" (macOS command line).
//
// Usage (on a Mac):
//   swift vision_ocr_zoom.swift <frames_folder> > ocr_zoom.json
//
// Why: small/far sign text ("GAMING", "Epic Games") is too few pixels for Vision on a 720p frame.
// Steps per frame:
//   1. read the whole frame (same settings as vision_ocr.swift)
//   2. find WHERE text is (VNDetectTextRectanglesRequest - finds text it cannot necessarily read)
//   3. pad each text box and merge touching boxes into blocks, so a word/line is never cut in half
//   4. blocks with small text, or text the full read missed, are cropped, enlarged (up to 4x) and read again
//   5. a zoomed reading replaces the overlapping full-frame reading; new text is added
//
// Output: same as vision_ocr.swift:
//   { "f00585.jpg": [ {"text": "...", "conf": 0.98, "box": [x, y, w, h], "src": "full"|"zoom"}, ... ] }
// box is normalized 0..1 with origin TOP-left.

import Foundation
import Vision
import AppKit

let TARGET_LINE_PX: CGFloat = 48      // enlarge so a text line is about this tall
let MAX_SCALE: CGFloat = 4
let SMALL_TEXT: CGFloat = 0.04        // line height (fraction of frame) below which we always zoom
let MAX_BLOCKS = 12                   // per frame, keeps run time bounded

struct Obs { var text: String; var conf: Double; var rect: CGRect; var src: String }  // rect: normalized, bottom-left origin

func recognize(_ cg: CGImage, minHeight: Float) -> [(String, Double, CGRect)] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate          // fast mode misses small sign text
    req.usesLanguageCorrection = false        // correction "fixes" phone digits and brand names
    req.recognitionLanguages = ["en-US"]
    req.minimumTextHeight = minHeight
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).compactMap { (o: VNRecognizedTextObservation) -> (String, Double, CGRect)? in
        guard let t = o.topCandidates(1).first else { return nil }
        return (t.string, Double(t.confidence), o.boundingBox)
    }
}

func textRegions(_ cg: CGImage) -> [CGRect] {
    let req = VNDetectTextRectanglesRequest()
    req.reportCharacterBoxes = false
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).map { $0.boundingBox }
}

func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

/// fraction of r covered by the union-ish of boxes (sum of intersections, capped at 1)
func covered(_ r: CGRect, by boxes: [CGRect]) -> CGFloat {
    let a = area(r)
    if a <= 0 { return 1 }
    return min(1, boxes.reduce(0) { $0 + area(r.intersection($1)) } / a)
}

/// pad every text box, then merge overlapping padded boxes until stable -> blocks that never cut a word
func blocks(_ regions: [CGRect]) -> [(rect: CGRect, lineH: CGFloat, members: [CGRect])] {
    var bs: [(rect: CGRect, lineH: CGFloat, members: [CGRect])] = regions.map { (r: CGRect) -> (rect: CGRect, lineH: CGFloat, members: [CGRect]) in
        let p = max(r.height * 0.6, 0.01)
        // wide sideways: text detection often misses the end of a line
        let padded = r.insetBy(dx: -3 * p, dy: -p).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return (padded, r.height, [r])
    }
    var merged = true
    while merged {
        merged = false
        outer: for i in 0..<bs.count {
            for j in (i + 1)..<bs.count where bs[i].rect.intersects(bs[j].rect) {
                bs[i] = (bs[i].rect.union(bs[j].rect), min(bs[i].lineH, bs[j].lineH), bs[i].members + bs[j].members)
                bs.remove(at: j)
                merged = true
                break outer
            }
        }
    }
    return bs
}

func enlarge(_ cg: CGImage, _ norm: CGRect, scale: CGFloat) -> (CGImage, CGRect)? {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    // CGImage cropping uses TOP-left pixel coordinates
    var px = CGRect(x: norm.minX * W, y: (1 - norm.maxY) * H, width: norm.width * W, height: norm.height * H).integral
    px = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
    guard px.width >= 4, px.height >= 4, let crop = cg.cropping(to: px) else { return nil }
    let w = Int(px.width * scale), h = Int(px.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let big = ctx.makeImage() else { return nil }
    // the crop actually used, back in normalized bottom-left coordinates
    let used = CGRect(x: px.minX / W, y: 1 - px.maxY / H, width: px.width / W, height: px.height / H)
    return (big, used)
}

func ocr(_ url: URL) -> [[String: Any]] {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let H = CGFloat(cg.height)

    // 1. whole frame
    var obs = recognize(cg, minHeight: 0.015).map { Obs(text: $0.0, conf: $0.1, rect: $0.2, src: "full") }

    // 2-3. where is text, grouped into uncut blocks
    let fullBoxes = obs.map { $0.rect }
    var todo = blocks(textRegions(cg)).filter { (b: (rect: CGRect, lineH: CGFloat, members: [CGRect])) -> Bool in
        let small = b.lineH < SMALL_TEXT
        let missed = b.members.contains { m in covered(m, by: fullBoxes) < 0.6 }
        return small || missed
    }
    todo.sort { $0.lineH < $1.lineH }                 // smallest text first
    if todo.count > MAX_BLOCKS { todo = Array(todo.prefix(MAX_BLOCKS)) }

    // 4-5. zoom and read again
    for b in todo {
        let scale = min(MAX_SCALE, max(1, TARGET_LINE_PX / max(1, b.lineH * H)))
        if scale < 1.3 && !b.members.contains(where: { m in covered(m, by: fullBoxes) < 0.6 }) { continue }
        guard let zoomed = enlarge(cg, b.rect, scale: scale) else { continue }
        let (big, used) = zoomed
        for (text, conf, bb) in recognize(big, minHeight: 0) {
            let r = CGRect(x: used.minX + bb.minX * used.width, y: used.minY + bb.minY * used.height,
                           width: bb.width * used.width, height: bb.height * used.height)
            // Text detection sometimes finds only part of a line, so a zoomed read can be a fragment
            // ("ARDUINO HARDWAR" of "ARDUINO HARDWARE FLOOR"). Rules (tested on 298 frames):
            //  - overlaps no full reading and nothing already added -> new text, add it
            //  - replaces full readings only if it covers each of them (>= 80%) and is about as confident
            //  - otherwise dropped
            let overlapping = obs.indices.filter { i in
                obs[i].src == "full" && area(obs[i].rect.intersection(r)) > 0.3 * min(area(obs[i].rect), area(r))
            }
            if overlapping.isEmpty {
                if !obs.contains(where: { area($0.rect.intersection(r)) > 0.3 * area(r) }) {
                    obs.append(Obs(text: text, conf: conf, rect: r, src: "zoom"))
                }
                continue
            }
            let coversAll = overlapping.allSatisfy { i in area(obs[i].rect.intersection(r)) >= 0.8 * area(obs[i].rect) }
            let maxConf = overlapping.map { obs[$0].conf }.max() ?? 0
            if !coversAll || conf < maxConf - 0.1 { continue }
            for i in overlapping.sorted(by: >) { obs.remove(at: i) }
            obs.append(Obs(text: text, conf: conf, rect: r, src: "zoom"))
        }
    }

    return obs.map { (o: Obs) -> [String: Any] in
        ["text": o.text, "conf": o.conf,
         "box": [Double(o.rect.minX), Double(1 - o.rect.maxY), Double(o.rect.width), Double(o.rect.height)],
         "src": o.src]
    }
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = (try FileManager.default.contentsOfDirectory(atPath: folder.path))
    .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".png") }
    .sorted()

var result: [String: Any] = [:]
for (n, f) in files.enumerated() {
    result[f] = ocr(folder.appendingPathComponent(f))
    if n % 20 == 0 { FileHandle.standardError.write("\(n + 1)/\(files.count)\n".data(using: .utf8)!) }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
