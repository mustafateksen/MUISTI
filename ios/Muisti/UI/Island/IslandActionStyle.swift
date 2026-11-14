import SwiftUI

/// The island's main button: filled for "fix it / start", quieter for "stop".
struct IslandActionStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.22)), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
