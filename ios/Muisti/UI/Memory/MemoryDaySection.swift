import Foundation

/// Records grouped by calendar day, newest day first, for the memory list.
struct MemoryDaySection: Identifiable {
    let day: Date
    let records: [MemoryRecord]
    var id: Date { day }

    static func group(_ records: [MemoryRecord], calendar: Calendar) -> [MemoryDaySection] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.seenAt) }
            .map { MemoryDaySection(day: $0.key, records: $0.value.sorted { $0.seenAt > $1.seenAt }) }
            .sorted { $0.day > $1.day }
    }

    func title(calendar: Calendar) -> String { Self.title(day, calendar: calendar) }

    static func title(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Episodes by the day they started, newest first.
    static func groupEpisodes(_ episodes: [MemoryEpisode], calendar: Calendar) -> [(day: Date, episodes: [MemoryEpisode])] {
        Dictionary(grouping: episodes) { calendar.startOfDay(for: $0.startedAt) }
            .map { ($0.key, $0.value.sorted { $0.endedAt > $1.endedAt }) }
            .sorted { $0.0 > $1.0 }
    }
}

extension MemoryRecord {
    /// Case- and accent-insensitive match on everything a person might remember about a record.
    func matches(_ query: String) -> Bool {
        let fields = [title, ocrText, street, phone, kind, name, hours, caption, keywords, otherText]
        return fields.contains { field in
            guard let field else { return false }
            return field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
