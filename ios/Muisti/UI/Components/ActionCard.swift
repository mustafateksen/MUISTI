import SwiftUI

/// Asks the user for exactly one next step: connect the glasses, grant camera access, add a key…
struct ActionCard: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: Theme.Radius.small))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(tint)
                    .padding(.top, Theme.Spacing.xxs)
            }
        }
        .card(padding: Theme.Spacing.m)
    }
}

#Preview {
    ActionCard(
        icon: "eyeglasses",
        title: "Gözlüğü bağla",
        message: "Meta AI uygulamasına geçip Muisti'yi onaylayacaksın.",
        button: "Bağlan"
    ) {}
    .padding()
}
