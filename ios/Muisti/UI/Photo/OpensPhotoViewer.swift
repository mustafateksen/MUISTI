import SwiftUI

/// Makes a keyframe tappable: opens it full screen (zoom transition on iOS 18+), shows a small
/// "expand" badge, and offers save/open in a long-press menu.
struct OpensPhotoViewer: ViewModifier {
    let url: URL
    var title: String?
    @State private var presented = false
    @State private var toast: PhotoToast?
    @Namespace private var zoom

    func body(content: Content) -> some View {
        Button {
            presented = true
        } label: {
            content
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(Theme.Spacing.s)
                        .accessibilityHidden(true)
                }
                .overlay {
                    if let toast {
                        Label(toast.text, systemImage: toast.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.s)
                            .background(.black.opacity(0.6), in: Capsule())
                            .transition(.opacity)
                    }
                }
        }
        .buttonStyle(PhotoPressStyle())
        .modifier(ZoomSource(id: url, namespace: zoom))
        .contextMenu {
            Button("View full screen", systemImage: "arrow.up.left.and.arrow.down.right") { presented = true }
            Button("Save to Photos", systemImage: "square.and.arrow.down", action: save)
        }
        .accessibilityLabel(title.map { "\($0), photo" } ?? "Photo")
        .accessibilityHint("Tap to view full screen.")
        .accessibilityAction(named: "Save to Photos", save)
        .animation(Theme.Motion.standard, value: toast)
        .fullScreenCover(isPresented: $presented) {
            PhotoViewer(url: url, title: title)
                .modifier(ZoomDestination(id: url, namespace: zoom))
        }
    }

    private func save() {
        Task {
            do {
                try await PhotoSaver.save(contentsOf: url)
                toast = .saved
            } catch PhotoSaver.Failure.denied {
                toast = .denied
            } catch {
                toast = .failed
            }
            let shown = toast
            try? await Task.sleep(for: .seconds(2))
            if toast == shown { toast = nil }
        }
    }
}

extension View {
    /// Tap to open this keyframe full screen (zoom, save to Photos, share).
    func opensPhotoViewer(url: URL, title: String? = nil) -> some View {
        modifier(OpensPhotoViewer(url: url, title: title))
    }
}

/// Slight shrink while pressed, so the photo feels tappable.
private struct PhotoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// iOS 18 zoom transition source; nothing on iOS 17.
private struct ZoomSource: ViewModifier {
    let id: URL
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// iOS 18 zoom transition destination; the default cover slide on iOS 17.
private struct ZoomDestination: ViewModifier {
    let id: URL
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
