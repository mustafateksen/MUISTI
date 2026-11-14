import SwiftUI

/// Where home is, for "when I leave home" rules. Saved from the current location.
struct SafetyHomeCard: View {
    let hasHome: Bool
    let setHomeHere: () -> Bool
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: hasHome ? "house.fill" : "house")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasHome ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 36, height: 36)
                    .background(hasHome ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.14)), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasHome ? "Home is set" : "Home isn't set")
                        .font(.body.weight(.medium))
                    Text("Used by “when I leave home” rules.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(hasHome ? "Move here" : "Set here") {
                    message = setHomeHere() ? "Home saved." : "No location yet. Start recording first."
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .font(.subheadline.weight(.semibold))
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card(padding: Theme.Spacing.m)
    }
}
