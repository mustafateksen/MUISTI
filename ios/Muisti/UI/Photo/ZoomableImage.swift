import SwiftUI

/// An image that fits the screen and can be pinched (up to 5×), double-tapped to 2.5×,
/// panned while zoomed, or dragged down to close when not zoomed.
struct ZoomableImage: View {
    let image: UIImage
    @Binding var dismissOffset: CGFloat
    var onTap: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStart: (scale: CGFloat, offset: CGSize)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: container.width, height: container.height)
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dismissOffset)
                .scaleEffect(1 - min(abs(dismissOffset) / 1600, 0.15))
                .contentShape(.rect)
                .gesture(magnify(in: container))
                .simultaneousGesture(drag(in: container))
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    doubleTap(at: location, in: container)
                }
                .onTapGesture(perform: onTap)
        }
        .accessibilityElement()
        .accessibilityLabel("Fotoğraf")
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Yakınlaştırmak için iki kez dokun.")
        .accessibilityZoomAction { action in
            withAnimation(Theme.Motion.standard) {
                scale = action.direction == .zoomIn ? min(scale * 1.6, Self.maxScale) : max(scale / 1.6, 1)
                if scale == 1 { offset = .zero }
            }
        }
    }

    // MARK: Gestures

    private func magnify(in container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = gestureStart ?? (scale, offset)
                gestureStart = start
                let newScale = min(max(start.scale * value.magnification, 0.6), Self.maxScale * 1.2)
                let anchor = CGPoint(x: value.startLocation.x - container.width / 2,
                                     y: value.startLocation.y - container.height / 2)
                offset = Self.offset(keeping: anchor, from: start.offset, ratio: newScale / start.scale)
                scale = newScale
            }
            .onEnded { _ in
                gestureStart = nil
                settle(in: container)
            }
    }

    private func drag(in container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.01 {
                    let start = gestureStart ?? (scale, offset)
                    gestureStart = start
                    offset = CGSize(width: start.offset.width + value.translation.width,
                                    height: start.offset.height + value.translation.height)
                } else {
                    dismissOffset = value.translation.height
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    gestureStart = nil
                    settle(in: container)
                } else if abs(value.predictedEndTranslation.height) > 260 || abs(value.translation.height) > 140 {
                    onDismiss()
                } else {
                    withAnimation(.spring(duration: 0.35)) { dismissOffset = 0 }
                }
            }
    }

    private func doubleTap(at location: CGPoint, in container: CGSize) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
            if scale > 1.01 {
                scale = 1
                offset = .zero
            } else {
                let anchor = CGPoint(x: location.x - container.width / 2, y: location.y - container.height / 2)
                offset = Self.offset(keeping: anchor, from: .zero, ratio: Self.doubleTapScale)
                scale = Self.doubleTapScale
                offset = clamped(offset, in: container)
            }
        }
    }

    /// Snap back inside the allowed range after a gesture.
    private func settle(in container: CGSize) {
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            scale = min(max(scale, 1), Self.maxScale)
            offset = scale <= 1.01 ? .zero : clamped(offset, in: container)
        }
    }

    // MARK: Geometry

    /// Offset that keeps the content under `anchor` (relative to the centre) in place
    /// when the scale changes by `ratio`.
    private static func offset(keeping anchor: CGPoint, from offset: CGSize, ratio: CGFloat) -> CGSize {
        CGSize(width: anchor.x - (anchor.x - offset.width) * ratio,
               height: anchor.y - (anchor.y - offset.height) * ratio)
    }

    /// Keeps the zoomed image covering the screen where it can.
    private func clamped(_ offset: CGSize, in container: CGSize) -> CGSize {
        let fitted = fittedSize(in: container)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return container }
        let ratio = min(container.width / image.size.width, container.height / image.size.height)
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    }
}
