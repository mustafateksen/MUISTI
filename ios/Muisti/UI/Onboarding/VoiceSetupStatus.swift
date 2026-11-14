import SwiftUI

/// Whether Ava (Premium) is on the phone yet.
struct VoiceSetupStatus: View {
    let installed: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(installed ? AnyShapeStyle(.success) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ava (Premium)")
                    .font(.headline)
                Text(installed ? "Installed. Muisti speaks with Ava." : "Not installed yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card(padding: Theme.Spacing.m)
        .accessibilityElement(children: .combine)
    }
}
