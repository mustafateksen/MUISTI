import SwiftUI

/// A stored (blurred) keyframe, loaded off the main thread.
///
/// Drawn with `Canvas` into exactly the frame its parent gives it. Nothing inside can be
/// larger than the box: a `scaledToFill` image (or one in a `ZStack`) made detail pages grow
/// wider than the screen with a zoomed-in photo, and even when clipped it still reported its
/// full, wider frame.
/// - `.fill` crops to the frame (list thumbnails).
/// - `.fit` shows the whole photo over a blurred copy of itself (detail and evidence views).
struct KeyframeImage: View {
    let url: URL
    var maxPixel = 600
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        Canvas { context, size in
            guard let image, image.size.width > 0, image.size.height > 0 else { return }
            let resolved = context.resolve(Image(uiImage: image))
            if contentMode == .fit {
                context.drawLayer { layer in
                    layer.opacity = 0.5
                    layer.addFilter(.blur(radius: 24))
                    layer.draw(resolved, in: Self.rect(for: image.size, in: size, fill: true))
                }
            }
            context.draw(resolved, in: Self.rect(for: image.size, in: size, fill: contentMode == .fill))
        }
        .background(.background.tertiary)
        .overlay {
            if image == nil { ProgressView() }
        }
        .clipped()
        .animation(Theme.Motion.standard, value: image == nil)
        .task(id: url) {
            let url = url, maxPixel = maxPixel
            image = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url), let cg = ImageData.thumbnail(data, maxPixel: maxPixel) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
        .accessibilityHidden(true)
    }

    /// Aspect-fill or aspect-fit rectangle for an image of `imageSize`, centred in `size`.
    static func rect(for imageSize: CGSize, in size: CGSize, fill: Bool) -> CGRect {
        let sx = size.width / imageSize.width, sy = size.height / imageSize.height
        let scale = fill ? max(sx, sy) : min(sx, sy)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
