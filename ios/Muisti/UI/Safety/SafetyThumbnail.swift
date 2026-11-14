import SwiftUI

/// A small square evidence photo that opens full screen on tap; a tinted symbol without one.
struct SafetyThumbnail: View {
    let url: URL?
    var title: String?
    var symbol = "eye.fill"
    var tint: Color = .brand
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url {
                KeyframeImage(url: url, maxPixel: 300, contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 10))
                    .opensPhotoViewer(url: url, title: title, showsBadge: false)
            } else {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
        }
    }
}
