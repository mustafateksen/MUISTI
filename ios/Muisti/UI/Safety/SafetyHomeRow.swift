import SwiftUI

/// Where home is, for "when I leave home" rules.
struct SafetyHomeRow: View {
    let hasHome: Bool
    let setHomeHere: () -> Bool
    @State private var failed = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SafetyThumbnail(url: nil, symbol: hasHome ? "house.fill" : "house")
            VStack(alignment: .leading, spacing: 3) {
                Text("Home")
                    .font(.subheadline.weight(.semibold))
                Text(failed ? String(localized: "No location yet. Start recording first.") : hasHome ? String(localized: "Saved") : String(localized: "Not set"))
                    .font(.caption)
                    .foregroundStyle(failed ? AnyShapeStyle(.danger) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(hasHome ? String(localized: "Move here") : String(localized: "Set here")) {
                failed = !setHomeHere()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.caption.weight(.semibold))
        }
    }
}
