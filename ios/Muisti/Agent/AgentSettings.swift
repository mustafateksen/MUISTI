import Foundation
import Observation

/// What the user lets the agent do, and how often it may speak up. Kept in UserDefaults.
@Observable
@MainActor
final class AgentSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Muisti brings things up by itself (reminders, notes from what it sees). Safety warnings
    /// are not part of this switch.
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "agent.enabled") } }
    /// Notices things in frames without being asked (closing times, warnings, prices, events).
    var noticing: Bool { didSet { defaults.set(noticing, forKey: "agent.noticing") } }
    /// Directions: a destination, wrong way, arrival, where the car is.
    var navigation: Bool { didSet { defaults.set(navigation, forKey: "agent.navigation") } }
    /// Text read from name badges and cards of people may be brought up. Off unless the user
    /// turns it on; faces are never recognised either way.
    var people: Bool { didSet { defaults.set(people, forKey: "agent.people") } }
    /// Reads the calendar's next 24 hours (titles, times, places) and gives them to the model.
    var calendar: Bool { didSet { defaults.set(calendar, forKey: "agent.calendar") } }
    /// Looks up places by name with Apple Maps (the place words leave the phone).
    var mapSearch: Bool { didSet { defaults.set(mapSearch, forKey: "agent.mapSearch") } }
    /// A short summary of the day in the evening.
    var eveningDigest: Bool { didSet { defaults.set(eveningDigest, forKey: "agent.digest") } }
    /// Spoken interventions per day that are not safety warnings.
    var dailySpokenBudget: Int { didSet { defaults.set(dailySpokenBudget, forKey: "agent.budget2") } }
    /// Minutes between two of them.
    var minGapMinutes: Int { didSet { defaults.set(minGapMinutes, forKey: "agent.minGap2") } }
    /// Quiet hours, as hours of the day (start == end: none). Safety warnings ignore them.
    var quietFromHour: Int { didSet { defaults.set(quietFromHour, forKey: "agent.quietFrom") } }
    var quietToHour: Int { didSet { defaults.set(quietToHour, forKey: "agent.quietTo") } }
    var digestHour: Int { didSet { defaults.set(digestHour, forKey: "agent.digestHour") } }

    init() {
        let stored = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool { stored.object(forKey: key) as? Bool ?? fallback }
        func number(_ key: String, _ fallback: Int) -> Int { stored.object(forKey: key) as? Int ?? fallback }
        enabled = flag("agent.enabled", true)
        noticing = flag("agent.noticing", true)
        navigation = flag("agent.navigation", true)
        people = flag("agent.people", false)
        calendar = flag("agent.calendar", false)
        mapSearch = flag("agent.mapSearch", true)
        eveningDigest = flag("agent.digest", true)
        dailySpokenBudget = number("agent.budget2", 40)
        minGapMinutes = number("agent.minGap2", 2)
        quietFromHour = number("agent.quietFrom", 22)
        quietToHour = number("agent.quietTo", 7)
        digestHour = number("agent.digestHour", 20)
    }

    func isQuiet(_ now: Date) -> Bool {
        guard quietFromHour != quietToHour else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        return quietFromHour < quietToHour ? (quietFromHour..<quietToHour).contains(hour)
            : hour >= quietFromHour || hour < quietToHour
    }
}
