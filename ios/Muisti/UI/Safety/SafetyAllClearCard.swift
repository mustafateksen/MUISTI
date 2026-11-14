import SwiftUI

/// No open warnings.
struct SafetyAllClearCard: View {
    let hasRules: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.success, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear")
                    .font(.headline)
                Text(hasRules ? "Nothing needs your attention right now." : "Add a rule below and Muisti will watch for it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: Theme.Spacing.m)
    }
}
