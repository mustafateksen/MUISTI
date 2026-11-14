import SwiftUI

/// A floating glass capsule: the text field, and one round button that is the voice orb's
/// little sibling (tap to talk) or "send" once something is typed.
struct ChatComposer: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let isBusy: Bool
    let onSend: () -> Void
    let onVoice: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            TextField("Ask Muisti", text: $text)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.leading, Theme.Spacing.l)
                .frame(minHeight: 44)

            ZStack {
                if hasText {
                    Button("Send", systemImage: "arrow.up", action: onSend)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.gradient, in: Circle())
                        .disabled(isBusy)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: onVoice) {
                        Image(systemName: "waveform")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(VoiceBadgeGradient(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask by voice")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hasText)
        }
        .padding(Theme.Spacing.xs)
        .glassCapsule()
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
    }
}
