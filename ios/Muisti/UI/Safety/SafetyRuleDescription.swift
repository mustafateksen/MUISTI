import Foundation

/// A rule's trigger in a few words and as a symbol, for rows and the add-rule preview.
extension SafetyRule {
    var triggerSymbol: String {
        switch trigger.type {
        case .context: "house.fill"
        case .schedule: "alarm.fill"
        case .event: "eye.fill"
        case .inactivity: "hourglass"
        }
    }

    var triggerText: String {
        switch trigger.type {
        case .context:
            trigger.event == "arrived_home" ? String(localized: "When you get home") : String(localized: "When you leave home")
        case .schedule:
            trigger.time.map { String(localized: "Every day at \($0)") } ?? String(localized: "On a schedule")
        case .event:
            trigger.object == "label" ? String(localized: "When you look at a product label")
                : String(localized: "When Muisti sees \(SafetyNames.display(trigger.object ?? watch.first ?? String(localized: "it", comment: "Fallback object name in a rule trigger")).lowercased())")
        case .inactivity:
            String(localized: "After \(trigger.minutes ?? 0) min of \(SafetyNames.display(trigger.object ?? String(localized: "it", comment: "Fallback object name in a rule trigger")).lowercased()) \(trigger.state ?? String(localized: "unchanged"))")
        }
    }
}
