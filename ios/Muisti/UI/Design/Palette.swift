import SwiftUI

/// The one colour palette of the app. Every tint, chip, status and the voice orb come from
/// here (the asset catalogue's AccentColor is `brand`), so the tab bar, the glasses island,
/// buttons and the orb all read as one family.
///
/// Core: #0064E0 · #0081FB · #1ABCFE · #1C2B33. Amber and rose are kept only as status
/// signals (attention, problem), where a blue would not read as a warning.
enum Palette {
    typealias RGB = SIMD3<Double>

    /// #0064E0 deep blue: tab bar, buttons, links, the user's bubbles.
    static let brand = RGB(0x00, 0x64, 0xE0) / 255
    /// #0081FB bright blue, the brand's light side.
    static let blue = RGB(0x00, 0x81, 0xFB) / 255
    /// #1ABCFE cyan: highlights, connected, done.
    static let sky = RGB(0x1A, 0xBC, 0xFE) / 255
    /// #1C2B33 ink: dark surfaces (the glasses island).
    static let ink = RGB(0x1C, 0x2B, 0x33) / 255
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
    static var brandBlue: Color { Palette.color(Palette.blue) }
    static var brandSky: Color { Palette.color(Palette.sky) }
    static var ink: Color { Palette.color(Palette.ink) }
    static var success: Color { Palette.color(Palette.sky) }
    static var attention: Color { Palette.color(Palette.amber) }
    static var danger: Color { Palette.color(Palette.rose) }
}
