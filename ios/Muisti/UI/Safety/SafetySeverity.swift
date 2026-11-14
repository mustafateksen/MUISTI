import SwiftUI

/// How a rule's severity looks: word, symbol, palette colour.
extension SafetyRule.Severity {
    var title: String {
        switch self {
        case .high: String(localized: "Urgent")
        case .medium: String(localized: "Warning")
        case .low: String(localized: "Reminder")
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
