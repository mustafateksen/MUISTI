import SwiftUI

/// How a rule's severity looks: word, symbol, palette colour.
extension SafetyRule.Severity {
    var title: String {
        switch self {
        case .high: "Urgent"
        case .medium: "Warning"
        case .low: "Reminder"
        }
    }

    var symbol: String {
        switch self {
        case .high: "exclamationmark.triangle.fill"
        case .medium: "bell.fill"
        case .low: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .high: .danger
        case .medium: .attention
        case .low: .brand
        }
    }
}
