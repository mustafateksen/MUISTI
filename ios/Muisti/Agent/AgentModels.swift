import CoreLocation
import Foundation

/// When an intent should come up again. Filled in by the model from what the user said
/// (`TurnTools`) or from what a frame showed (`Notice`); the app only runs it.
struct Cue: Codable, Sendable, Equatable {
    /// One moment, local time, "yyyy-MM-dd HH:mm".
    var at: String?
    /// Every day at "HH:mm".
    var daily: String?
    /// A place: one of the user's named places, or words a map search understands
    /// ("a grocery store", "Stockmann").
    var place: String?
    /// What the glasses would see when it is time, one sentence.
    var sight: String?
    /// "leaving_home" or "arriving_home".
    var on: String?

    var isEmpty: Bool { at == nil && daily == nil && place == nil && sight == nil && on == nil }

    init(at: String? = nil, daily: String? = nil, place: String? = nil, sight: String? = nil, on: String? = nil) {
        self.at = at; self.daily = daily; self.place = place; self.sight = sight; self.on = on
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            let value = c.lenientString(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        at = text(.at); daily = text(.daily); place = text(.place); sight = text(.sight); on = text(.on)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func stamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: date) }

    /// The next moment the time part is due, after `after` (nil: no time part, or it has passed).
    func nextDue(after: Date) -> Date? {
        if let at {
            let clean = at.replacingOccurrences(of: "T", with: " ")
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
                if let date = Self.formatter(format).date(from: clean) { return date }
            }
        }
        if let daily, let time = Self.formatter("HH:mm").date(from: daily) {
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            return calendar.nextDate(after: after, matching: parts, matchingPolicy: .nextTime)
        }
        return nil
    }
}

/// Something Muisti keeps in mind for the user: what they asked to be reminded of, where they
/// are heading, where the car is, or a note the agent made for itself from a frame.
struct Intent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case reminder, todo, destination, watch, parking, followup }
    enum Status: String, Codable, Sendable { case open, done, dropped }
    enum Source: String, Codable, Sendable { case user, agent }

    var id: String = String(UUID().uuidString.prefix(8)).lowercased()
    var kind: Kind = .reminder
    /// What it is about, in the user's words and language.
    var text: String
    /// What Muisti says when it comes up, in the user's language.
    var say: String?
    var cue = Cue()
    var status: Status = .open
    var source: Source = .user
    var language: String?
    var createdAt = Date()
    var snoozeUntil: Date?
    var firedAt: Date?
    var fireCount = 0
    /// A place the cue was resolved to (destination, parking spot).
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    /// Memory record this came from (a note made from a frame).
    var recordID: Int64?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func isSnoozed(_ now: Date) -> Bool { snoozeUntil.map { now < $0 } ?? false }
}

struct NamedPlace: Codable, Sendable, Equatable, Identifiable {
    var id: String { name.lowercased() }
    /// "home", "work", "car", or what the user called it.
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 80
    var setAt = Date()
    /// Street / area / floor when it was set.
    var detail: String?

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

struct UserFact: Codable, Sendable, Equatable, Identifiable {
    var id: Int64 = 0
    var text: String
    var at = Date()
}

/// How loudly Muisti brings something up.
enum InterventionLevel: Int, Codable, Sendable, Comparable {
    case silent = 0, notification, chime, spoken
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How much it matters now, as judged by whoever proposes it.
enum Urgency: String, Codable, Sendable, CaseIterable {
    /// Danger or health: always spoken, outside the daily budget.
    case safety
    /// Useless unless said now (wrong turn, closing soon, the shop is right here).
    case timely
    /// Good to know today; can wait for a quiet moment.
    case useful
    /// Only worth keeping.
    case fyi
}

/// One thing Muisti brought up by itself — or decided not to. The record of what was said, how,
/// and how the user took it: the daily budget, the per-topic pauses and "don't tell me this
/// again" all read this.
struct Intervention: Codable, Sendable, Equatable, Identifiable {
    enum Outcome: String, Codable, Sendable { case accepted, dismissed, snoozed, muted, unanswered, expired }

    var id: Int64 = 0
    var at = Date()
    /// "safety" or "agent".
    var source: String
    /// A short stable name for what it is about ("shopping", "navigation", "intent:ab12cd34").
    var topic: String
    var urgency: Urgency
    var level: InterventionLevel
    var text: String
    var language: String?
    var intentID: String?
    var recordID: Int64?
    /// Why this level (budget used up, quiet hours, muted, held and expired…).
    var reason: String?
    var outcome: Outcome?
}

struct Mute: Codable, Sendable, Equatable {
    var topic: String
    var until: Date?
    var at = Date()
}

/// What the user told Muisti to do with its agent side (from the turn's tool call).
enum AgentCommand: Sendable, Equatable {
    case remember(text: String, say: String?, kind: Intent.Kind, cue: Cue)
    case setDestination(String)
    case cancelDestination
    case complete(String)
    case drop(String)
    case rememberFact(String)
    case namePlace(String)
    case mute(topic: String?, intentID: String?, minutes: Int?)
    case summarizeDay
    case addToCalendar(title: String, start: String, minutes: Int?, location: String?)
}

/// A yes/no the agent is waiting on (things that leave Muisti's own memory need a yes).
enum AgentPending: Sendable, Equatable {
    case calendar(title: String, start: Date, minutes: Int, location: String?)

    var prompt: String {
        switch self {
        case .calendar(let title, let start, _, _): return "add “\(title)” to the user's calendar at \(Cue.stamp(start))?"
        }
    }
}
