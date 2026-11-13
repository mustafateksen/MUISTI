import SwiftUI

/// Three colours per assistant phase, as RGB so the visualizer can blend between phases.
enum VoicePalette {
    typealias RGB = SIMD3<Double>

    static func colors(for phase: VoiceAssistant.Phase) -> [RGB] {
        switch phase {
        case .idle: [RGB(0.36, 0.42, 0.98), RGB(0.30, 0.68, 1.00), RGB(0.62, 0.45, 1.00)]
        case .listening: [RGB(0.16, 0.52, 1.00), RGB(0.18, 0.86, 0.96), RGB(0.70, 0.36, 1.00)]
        case .thinking: [RGB(0.56, 0.32, 1.00), RGB(1.00, 0.38, 0.70), RGB(1.00, 0.62, 0.42)]
        case .speaking: [RGB(0.10, 0.76, 0.72), RGB(0.40, 0.90, 0.56), RGB(0.26, 0.60, 1.00)]
        case .failed: [RGB(1.00, 0.55, 0.25), RGB(1.00, 0.40, 0.36), RGB(1.00, 0.76, 0.42)]
        }
    }

    static func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity)
    }
}
