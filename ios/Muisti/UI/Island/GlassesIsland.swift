import SwiftUI

/// Glasses status in the top-left corner, Dynamic Island style: a small black pill with an icon
/// and a status dot that grows into a card when something changes. It stays open while there is
/// a problem (disconnected, paused, no permission) and shrinks once it is solved.
struct GlassesIsland: View {
    let status: IslandStatus
    let perform: (IslandAction) -> Void
    let showDetails: () -> Void

    @State private var expanded = false
    @State private var dismissedKey: String?
    @State private var holdTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 30 : 20, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if expanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topLeading)))
            } else {
                compactButton
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topLeading)))
            }
        }
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .topLeading)
        .background(.ink, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(expanded ? 0.25 : 0.12), radius: expanded ? 18 : 6, y: expanded ? 8 : 2)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.32), value: expanded)
        .animation(Theme.Motion.standard, value: status)
        .onChange(of: status.key, initial: true) { _, _ in
            if status.persistent, dismissedKey == status.key { return }
            expand()
        }
        .sensoryFeedback(trigger: status.key) { _, _ in
            status.persistent && status.tint != .attention ? .warning : nil
        }
    }

    // MARK: Compact

    private var compactButton: some View {
        Button(action: expand) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: status.symbol)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                StatusDot(tint: status.tint, pulsing: status.isRecording || status.persistent)
                if let badge = status.badge {
                    Text(badge)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minWidth: 64, minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Glasses: \(status.title)")
        .accessibilityHint("Tap to show details.")
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: status.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(status.tint == .secondary ? .white : status.tint)
                    .frame(width: 40, height: 40)
                    .background((status.tint == .secondary ? Color.white : status.tint).opacity(0.18), in: Circle())
                    .symbolEffect(.pulse, isActive: status.persistent && !reduceMotion)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(status.message)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                Button("Collapse", systemImage: "chevron.up", action: collapse)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .padding(.top, -Theme.Spacing.xs)
                    .padding(.trailing, -Theme.Spacing.s)
            }

            HStack(spacing: Theme.Spacing.s) {
                if let action = status.action {
                    Button {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(IslandActionStyle(prominent: action != .stop))
                    .tint(action == .stop ? .danger : .accentColor)
                }
                Button {
                    collapse()
                    showDetails()
                } label: {
                    Text("Details")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(IslandActionStyle(prominent: false))
                .tint(.white)
            }
        }
        .padding(Theme.Spacing.m)
        .contentShape(.rect)
        .onTapGesture(perform: collapse)
    }

    // MARK: Behaviour

    private func expand() {
        expanded = true
        holdTask?.cancel()
        guard !status.persistent else { return }
        // Good news and passing states show for a moment, then shrink back.
        // A newer status cancels this through `expand()` / `collapse()`.
        holdTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            expanded = false
        }
    }

    private func collapse() {
        holdTask?.cancel()
        if status.persistent { dismissedKey = status.key }
        expanded = false
    }
}
