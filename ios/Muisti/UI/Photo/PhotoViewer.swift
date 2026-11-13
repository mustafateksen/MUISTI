import SwiftUI

/// Full-screen keyframe: pinch or double-tap to zoom, drag to pan, swipe down to close,
/// save to Photos or share.
struct PhotoViewer: View {
    let url: URL
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var saved = false
    @State private var saving = false
    @State private var toast: PhotoToast?
    @State private var chromeVisible = true
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(abs(dismissOffset) / 400, 0.6))
                .ignoresSafeArea()

            if let image {
                ZoomableImage(image: image, dismissOffset: $dismissOffset, onTap: toggleChrome, onDismiss: { dismiss() })
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .top) {
            if chromeVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if let toast {
                Label(toast.text, systemImage: toast.symbol)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.m)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.standard, value: chromeVisible)
        .animation(Theme.Motion.standard, value: toast)
        .animation(Theme.Motion.standard, value: saved)
        .statusBarHidden(!chromeVisible)
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }.value
        }
    }

    private var topBar: some View {
        HStack {
            Button("Kapat", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
            Spacer()
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.xs)
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: save) {
                Label(saved ? "Kaydedildi" : "Fotoğraflara kaydet",
                      systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(image == nil || saving || saved)

            if let image {
                let preview = Image(uiImage: image)
                ShareLink(item: preview, preview: SharePreview(title ?? "Muisti anısı", image: preview)) {
                    Label("Paylaş", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    private func save() {
        saving = true
        Task {
            do {
                try await PhotoSaver.save(contentsOf: url)
                saved = true
                toast = .saved
            } catch PhotoSaver.Failure.denied {
                toast = .denied
            } catch {
                toast = .failed
            }
            saving = false
            let shown = toast
            try? await Task.sleep(for: .seconds(shown == .saved ? 1.6 : 3))
            if toast == shown { toast = nil }
        }
    }
}
