import SwiftUI

/// Shared spacing, rounding and motion so every screen feels like one app.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        /// Large cards on a screen.
        static let card: CGFloat = 24
        /// Images and blocks inside a card.
        static let inner: CGFloat = 16
        /// Small badges and thumbnails.
        static let small: CGFloat = 10
    }

    enum Motion {
        static let standard = Animation.smooth(duration: 0.35)
        static let snappy = Animation.snappy(duration: 0.25)
    }

    /// Soft brand wash behind the top of a screen.
    static let headerGradient = LinearGradient(
        colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.06), .clear],
        startPoint: .top,
        endPoint: .bottom
    )
}
