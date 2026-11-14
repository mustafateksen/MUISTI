import SwiftUI

/// Muisti is waiting for a yes/no (a new rule, deleting one, "did you take it?"). Dark card at
/// the top of the page with two equal answers; the frame leads when there is one.
struct SafetyPendingCard: View {
    let pending: SafetyPending
    let frameURL: URL?
    let answer: (Bool) -> Void

    private var title: String {
        switch pending {
        case .rule: "Add this rule?"
        case .deleteRule: "Delete this rule?"
        case .action: "Did this happen?"
        }
    }

    private var detail: String {
        switch pending {
        case .rule(let rule), .deleteRule(let rule): rule.summary
        case .action(let object, let action, _, let at):
            "\(SafetyNames.display(object)): \(action) · \(at.formatted(date: .omitted, time: .shortened))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let frameURL {
                KeyframeImage(url: frameURL, maxPixel: 1000, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .opensPhotoViewer(url: frameURL, title: detail)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Label("Muisti is asking", systemImage: "questionmark.bubble.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.brandSky)
                    Text(title)
                        .font(.title3.bold())
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: Theme.Spacing.s) {
                    Button { answer(true) } label: {
                        Text("Yes").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(IslandActionStyle(prominent: true))
                    .tint(.brand)
                    Button { answer(false) } label: {
                        Text("No").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(IslandActionStyle(prominent: false))
                    .tint(.white)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(Theme.Spacing.l)
        }
        .foregroundStyle(.white)
        .background(.ink, in: .rect(cornerRadius: Theme.Radius.card))
        .clipShape(.rect(cornerRadius: Theme.Radius.card))
        .environment(\.colorScheme, .dark)
    }
}
