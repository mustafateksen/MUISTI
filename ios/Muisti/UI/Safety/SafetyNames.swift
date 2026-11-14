import Foundation

/// Object names as the user reads them: "stove:kitchen" → "Stove · kitchen".
enum SafetyNames {
    static func display(_ object: String) -> String {
        let text = object.replacingOccurrences(of: ":", with: " · ").replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
