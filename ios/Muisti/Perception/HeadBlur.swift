import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import Vision

/// Finds heads (KVKK/GDPR) before a frame is stored or sent anywhere, and masks them
/// irreversibly. Adapted from the team's `FaceBlurrer` (yuz_bulaniklastirma):
/// - three detectors: face rectangles (frontal), body pose (side / bowed / turned-away heads
///   from nose-eye-ear or neck-shoulder points), upper body (fallback for anyone else),
/// - overlapping 2×2 tiles so small, distant faces look bigger to the detector,
/// - soft elliptical mask, pixellated first (not reversible) then blurred,
/// - fail-safe: if detection fails, the caller drops the frame.
///
/// Speed changes for the phone: the full frame runs all three detectors once; the tiles run
/// only the cheap face detector (pose / upper body find large people on the full frame
/// anyway), and masking is done on the downscaled keyframe, not the OCR-size image.
enum HeadBlur {
    /// Head boxes, normalised (0…1, Vision coordinates, origin bottom-left). nil = detection failed.
    static func heads(in image: CGImage) -> [CGRect]? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        var boxes: [CGRect] = []

        // 1. Full frame. Faces are essential: if that detector fails, the frame is dropped.
        //    Pose / upper body are extra coverage; each one that fails is logged and skipped
        //    (the body-pose model is not available everywhere, e.g. some simulators).
        let face = VNDetectFaceRectanglesRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let upper = VNDetectHumanRectanglesRequest()
        upper.upperBodyOnly = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        [face, pose, upper].forEach(prepare)
        do {
            try handler.perform([face])
        } catch {
            Log.pipeline.error("head blur: face detector failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        for extra in [pose, upper] as [VNRequest] {
            do {
                try handler.perform([extra])
            } catch {
                Log.pipeline.error("head blur: \(String(describing: type(of: extra)), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        boxes += (face.results ?? []).map { pad($0.boundingBox, by: 0.3) }
        let aspect = width / height
        boxes += (pose.results ?? []).compactMap { headFromPose($0, aspect: aspect) }
        let precise = boxes
        for body in upper.results ?? [] where body.confidence > 0.4 {
            let b = body.boundingBox
            guard !precise.contains(where: { b.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { continue }
            // Head ≈ top 38 % of the upper body, roughly square.
            let hh = b.height * 0.38
            let hw = min(b.width * 0.55, hh * 1.1 / aspect)
            boxes.append(CGRect(x: b.midX - hw / 2, y: b.maxY - hh, width: hw, height: hh * 1.05))
        }

        // 2. Tiles (face detector only) for small, distant faces.
        if min(width, height) >= 600 {
            for (fx, fy) in [(0.0, 0.0), (0.4, 0.0), (0.0, 0.4), (0.4, 0.4)] {
                let tile = CGRect(x: fx, y: fy, width: 0.6, height: 0.6)
                let request = VNDetectFaceRectanglesRequest()
                prepare(request)
                request.regionOfInterest = tile
                do {
                    try handler.perform([request])
                } catch {
                    Log.pipeline.error("head blur: tile face detector failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                // Results are normalised to the region of interest.
                boxes += (request.results ?? []).map { o in
                    let r = o.boundingBox
                    return pad(CGRect(x: tile.minX + r.minX * tile.width, y: tile.minY + r.minY * tile.height,
                                      width: r.width * tile.width, height: r.height * tile.height), by: 0.3)
                }
            }
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return mergeDuplicates(boxes.map { $0.intersection(unit) }.filter { !$0.isNull && !$0.isEmpty })
    }

    /// Masks `heads` (soft ellipses) and `plates` (rectangles) on `image`, both normalised.
    /// Pixellate first (irreversible), then blur so it is easy on the eye.
    static func mask(_ image: CIImage, heads: [CGRect], plates: [CGRect]) -> CIImage {
        guard !heads.isEmpty || !plates.isEmpty else { return image }
        let extent = image.extent
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: extent.minX + r.minX * extent.width, y: extent.minY + r.minY * extent.height,
                   width: r.width * extent.width, height: r.height * extent.height)
        }
        let headRects = heads.map(pixels)
        let plateRects = plates.map { pixels(pad($0, by: 0.25)).intersection(extent) }.filter { !$0.isEmpty }
        let largest = (headRects + plateRects).map { max($0.width, $0.height) }.max() ?? 0

        var mask = CIImage(color: .black).cropped(to: extent)
        for r in headRects {
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = 0.85   // fully covered inside the head box
            gradient.radius1 = 1.0    // short soft edge outside it
            gradient.color0 = .white
            gradient.color1 = .black
            guard let disc = gradient.outputImage else { continue }
            let ellipse = disc
                .transformed(by: CGAffineTransform(scaleX: r.width / 2 / 0.85, y: r.height / 2 / 0.85))
                .transformed(by: CGAffineTransform(translationX: r.midX, y: r.midY))
                .cropped(to: extent)
            mask = ellipse.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        for r in plateRects {
            mask = CIImage(color: .white).cropped(to: r).composited(over: mask)
        }

        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = image.clampedToExtent()
        pixellate.center = CGPoint(x: extent.minX, y: extent.minY)
        pixellate.scale = Float(max(10, largest / 7))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = pixellate.outputImage
        blur.radius = Float(max(6, largest / 9))
        guard let cover = blur.outputImage?.cropped(to: extent) else {
            // Never return the unmasked image: cover everything rather than leak a face.
            return CIImage(color: .black).cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = cover
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
    }

    // MARK: Helpers

    /// The simulator cannot create Neural Engine / GPU inference contexts for Vision ("Could
    /// not create inference context"): run there on the CPU. Devices keep Vision's default.
    static func prepare(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    private static func pad(_ r: CGRect, by fraction: CGFloat) -> CGRect {
        r.insetBy(dx: -r.width * fraction, dy: -r.height * fraction)
    }

    /// Head box from pose points: face points (nose/eyes/ears) if any, else neck + shoulders.
    /// Works in a square-pixel space (x scaled by aspect) and returns normalised coordinates.
    private static func headFromPose(_ o: VNHumanBodyPoseObservation, aspect: CGFloat) -> CGRect? {
        guard o.confidence > 0.3, let points = try? o.recognizedPoints(.all) else { return nil }
        func p(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let q = points[joint], q.confidence > 0.3 else { return nil }
            return CGPoint(x: q.location.x * aspect, y: q.location.y)
        }
        let face = [p(.nose), p(.leftEye), p(.rightEye), p(.leftEar), p(.rightEar)].compactMap { $0 }
        let neck = p(.neck)
        var shoulderWidth: CGFloat?
        if let l = p(.leftShoulder), let r = p(.rightShoulder) { shoulderWidth = hypot(l.x - r.x, l.y - r.y) }

        var center: CGPoint
        var size: CGFloat
        if !face.isEmpty {
            center = CGPoint(x: face.map(\.x).reduce(0, +) / CGFloat(face.count),
                             y: face.map(\.y).reduce(0, +) / CGFloat(face.count))
            let xs = face.map(\.x), ys = face.map(\.y)
            size = max((max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)) * 2.6, (shoulderWidth ?? 0) * 0.6)
            if let n = neck { size = max(size, hypot(center.x - n.x, center.y - n.y) * 1.4) }
            if let sw = shoulderWidth { size = min(size, sw * 0.95) }   // a head is not wider than the shoulders
        } else if let n = neck, let sw = shoulderWidth, sw > 0.005 {
            size = sw * 0.65                                           // turned away: head above the neck
            center = CGPoint(x: n.x, y: n.y + size * 0.6)
        } else {
            return nil
        }
        size = min(size, min(aspect, 1) * 0.3)                          // bad pose guesses made giant boxes
        guard size > 0.004 else { return nil }
        return CGRect(x: (center.x - size / 2) / aspect, y: center.y - size / 2, width: size / aspect, height: size)
    }

    /// Collapses boxes of the same person (IoU > 0.3 or > 60 % contained) when the union does
    /// not grow much, so boxes never snowball into blocks that cover signs.
    static func mergeDuplicates(_ input: [CGRect]) -> [CGRect] {
        var boxes = input.sorted { $0.width * $0.height > $1.width * $1.height }
        var changed = true
        while changed {
            changed = false
            var out: [CGRect] = []
            for b in boxes {
                if let i = out.firstIndex(where: { a in
                    let u = a.union(b)
                    return overlaps(a, b) && u.width * u.height <= 1.5 * max(a.width * a.height, b.width * b.height)
                }) {
                    out[i] = out[i].union(b)
                    changed = true
                } else {
                    out.append(b)
                }
            }
            boxes = out
        }
        return boxes
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return false }
        let ia = inter.width * inter.height, aa = a.width * a.height, ba = b.width * b.height
        return ia / (aa + ba - ia) > 0.3 || ia / min(aa, ba) > 0.6
    }
}
