import SwiftUI

/// Typed questions, pinned above the tab bar.
struct AskInputBar: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let isBusy: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            TextField("Ya da yazarak sor…", text: $text)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .frame(minHeight: 44)
                .background(.background.secondary, in: .rect(cornerRadius: 22))
            Button("Gönder", systemImage: "arrow.up.circle.fill", action: onSend)
                .labelStyle(.iconOnly)
                .font(.system(size: 34))
                .frame(width: 44, height: 44)
                .disabled(!canSend)
                .animation(Theme.Motion.snappy, value: canSend)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
    }
}
