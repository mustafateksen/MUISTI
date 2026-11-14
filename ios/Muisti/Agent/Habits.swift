import Foundation

/// What the user usually does, worked out from Muisti Turva's log of earlier days: which
/// logged things (an action on an object, a state it was put in) come back on most days, at
/// about what time, and whether they have happened today. Nothing here knows what a medicine
/// or a door is: it counts whatever the log holds. The agent's periodic look reads these lines
/// and decides by itself whether a habit missed today deserves a word.
enum Habits {
    struct Habit: Sendable, Equatable {
        /// "medicine taken", "front door locked": the log's own object and value.
        var what: String
        var days: Int
        var of: Int
        /// Earliest and latest time of day (minutes) of the first occurrence on those days.
        var from: Int
        var to: Int
        var today: Date?

        /// Usually done by now, and not today.
        func overdue(at now: Date, slack: Int = 30) -> Bool {
            today == nil && Habits.minutes(now) > to + slack
        }
    }

    /// Seen on at least this many earlier days, and on at least half of the days with a log.
    static let minDays = 3

    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func find(in events: [SafetyEvent], now: Date, lookBack: Int = 14) -> [Habit] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -lookBack, to: today) else { return [] }
        let counted = events.filter { $0.at >= start && $0.at <= now && ($0.kind == .action || $0.kind == .state || $0.kind == .context) }
        // Days before today on which the log has anything at all (days the glasses were worn).
        let loggedDays = Set(counted.filter { $0.at < today }.map { calendar.startOfDay(for: $0.at) })
        guard loggedDays.count >= minDays else { return [] }
        var byWhat: [String: [SafetyEvent]] = [:]
        for event in counted {
            let what = [event.object, event.value].compactMap { $0 }.joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            guard !what.isEmpty else { continue }
            byWhat[what, default: []].append(event)
        }
        var out: [Habit] = []
        for (what, list) in byWhat {
            var first: [Date: Date] = [:]
            for event in list where event.at < today {
                let day = calendar.startOfDay(for: event.at)
                if first[day].map({ event.at < $0 }) ?? true { first[day] = event.at }
            }
            guard first.count >= minDays, first.count * 2 >= loggedDays.count else { continue }
            let times = first.values.map(minutes)
            out.append(Habit(what: what, days: first.count, of: loggedDays.count, from: times.min() ?? 0, to: times.max() ?? 0,
                             today: list.filter { $0.at >= today }.map(\.at).min()))
        }
        return out.sorted { $0.from < $1.from }
    }

    private static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func lines(_ habits: [Habit], now: Date) -> [String] {
        habits.map { h in
            let usual = h.from == h.to ? "at about \(clock(h.from))" : "first between \(clock(h.from)) and \(clock(h.to))"
            let today = h.today.map { "today at \(clock(minutes($0)))" }
                ?? (h.overdue(at: now) ? "NOT today so far, and the usual time has passed" : "not today so far (the usual time has not passed)")
            return "- \(h.what): on \(h.days) of the last \(h.of) days with a log, \(usual); \(today)"
        }
    }
}
