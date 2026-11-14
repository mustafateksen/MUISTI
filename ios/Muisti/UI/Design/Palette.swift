import SwiftUI

/// The one colour palette of the app. Every tint, chip, status and the voice orb come from
/// here (the asset catalogue's AccentColor is `brand`), so the tab bar, the glasses island,
/// buttons and the orb all read as one family.
enum Palette {
    typealias RGB = SIMD3<Double>

    /// Indigo-violet: tab bar, buttons, links, the user's bubbles.
    static let brand = RGB(0.36, 0.34, 0.96)
    /// Sky blue, the brand's light side.
    static let sky = RGB(0.36, 0.72, 1.00)
    /// Soft violet, the brand's warm side.
    static let violet = RGB(0.66, 0.44, 1.00)
    /// Orchid pink (thinking).
    static let orchid = RGB(0.93, 0.45, 0.90)
    /// Calm teal-mint: done, connected, seen.
    static let mint = RGB(0.16, 0.72, 0.64)
    /// Warm amber: needs attention.
    static let amber = RGB(0.98, 0.64, 0.26)
    /// Rose: problems, stop, delete.
    static let rose = RGB(0.95, 0.36, 0.46)

    static func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity)
    }
}

/// Palette colours wherever a `Color` or `ShapeStyle` is expected: `.foregroundStyle(.success)`.
extension ShapeStyle where Self == Color {
    static var brand: Color { Palette.color(Palette.brand) }
    static var brandSky: Color { Palette.color(Palette.sky) }
    static var brandViolet: Color { Palette.color(Palette.violet) }
    static var success: Color { Palette.color(Palette.mint) }
    static var attention: Color { Palette.color(Palette.amber) }
    static var danger: Color { Palette.color(Palette.rose) }
}
