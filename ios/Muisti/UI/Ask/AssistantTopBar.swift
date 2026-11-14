import SwiftUI

/// Top of the assistant screen: the glasses island on the left; new chat, developer and
/// settings on the right. The island grows over the buttons, like the Dynamic Island.
struct AssistantTopBar: View {
    let status: IslandStatus
    let canClear: Bool
    let developerMode: Bool
    /// Fade scrolling content out under the bar (chat); off in voice mode so the glow shows.
    var fades = true
    let perform: (IslandAction) -> Void
    let showDetails: () -> Void
    let clear: () -> Void
    let showDeveloper: () -> Void
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Spacer()
            if canClear {
                barButton("New chat", systemImage: "square.and.pencil", action: clear)
                    .transition(.scale.combined(with: .opacity))
            }
            if developerMode {
                barButton("Developer", systemImage: "hammer", action: showDeveloper)
            }
            barButton("Settings", systemImage: "gearshape", action: showSettings)
        }
        .frame(minHeight: 44)
        .overlay(alignment: .topLeading) {
            GlassesIsland(status: status, perform: perform, showDetails: showDetails)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.s)
        .background {
            // Content scrolling up fades out under the bar instead of colliding with the island.
            Rectangle()
                .fill(.background)
                .opacity(fades ? 1 : 0)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.bottom, -Theme.Spacing.xl)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .zIndex(1)
        .animation(Theme.Motion.standard, value: canClear)
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
    }
}
