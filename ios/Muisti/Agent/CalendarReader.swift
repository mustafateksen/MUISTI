import EventKit
import Foundation

/// The user's next day of calendar events, for the agent's picture of what they are doing
/// (only when they switched it on and gave access), and adding an event they said yes to.
@MainActor
final class CalendarReader {
    struct Entry: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var allDay: Bool
    }

    private let store = EKEventStore()
    private(set) var upcoming: [Entry] = []
    private var refreshedAt: Date?

    var canRead: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestRead() async -> Bool {
        if canRead { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Events of the next 24 hours (re-read at most once a minute).
    func refresh(now: Date = Date(), force: Bool = false) {
        guard canRead else { upcoming = []; return }
        if !force, let refreshedAt, now.timeIntervalSince(refreshedAt) < 60 { return }
        refreshedAt = now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400), calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { Entry(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "(no title)", start: $0.startDate,
                         end: $0.endDate, location: $0.location.flatMap { $0.isEmpty ? nil : $0 }, allDay: $0.isAllDay) }
    }

    /// Adds an event to the default calendar (write-only access is enough). False: no access.
    func add(title: String, start: Date, minutes: Int, location: String?, notes: String?) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess, status != .writeOnly {
            guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return false }
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(max(15, minutes)) * 60)
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            refreshedAt = nil
            return true
        } catch {
            Log.app.error("calendar: could not save the event: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
