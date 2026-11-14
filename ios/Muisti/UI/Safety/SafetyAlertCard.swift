import SwiftUI

/// An open warning: the evidence frame fills the card, the message sits on it, and two equal
/// buttons answer it. Without a frame the card shows the severity colour instead.
struct SafetyAlertCard: View {
    let alert: SafetyAlert
    let frameURL: URL?
    let respond: (SafetyAlert.Response) -> Void

    var body: some View {
        VStack(spacing: 0) {
            hero
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    respond(.dismissed)
                } label: {
                    Text("Got it")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    respond(.snoozed)
                } label: {
                    Text("Remind me later")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .padding(Theme.Spacing.m)
        }
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.card))
        .clipShape(.rect(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private var hero: some View {
        let height: CGFloat = frameURL == nil ? 170 : 300
        Group {
            if let frameURL {
                KeyframeImage(url: frameURL, maxPixel: 1200, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay { scrim.allowsHitTesting(false) }
                    .overlay(alignment: .bottomLeading) { caption.allowsHitTesting(false) }
                    .opensPhotoViewer(url: frameURL, title: alert.message)
            } else {
                LinearGradient(colors: [alert.severity.tint, .ink], startPoint: .topTrailing, endPoint: .bottomLeading)
                    .frame(height: height)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: alert.severity.symbol)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.22))
                            .padding(Theme.Spacing.l)
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .bottomLeading) { caption }
            }
        }
    }

    private var scrim: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)], startPoint: .top, endPoint: .bottom)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(alert.severity.title, systemImage: alert.severity.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(alert.severity.tint, in: Capsule())
            Text(alert.message)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(alert.at, format: .relative(presentation: .named))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(Theme.Spacing.l)
        .padding(.trailing, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
