import SwiftUI

/// Loads a stored keyframe off the main thread, downsampled.
struct KeyframeImage: View {
    let url: URL
    var maxPixel = 600
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.background.tertiary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                ProgressView()
            }
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
}
