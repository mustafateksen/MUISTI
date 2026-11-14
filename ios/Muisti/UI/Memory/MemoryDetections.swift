import EventKit
import EventKitUI
import SwiftUI

/// What can be acted on in the text read from a frame: an event date on a poster, a web
/// address, an e-mail address, a postal address, a phone number. Found with the system's
/// data detector (the one Mail and Messages underline things with), only in text the phone's
/// OCR actually read — the same rule as for answers: nothing the model wrote is acted on.
struct MemoryDetections: Equatable {
    struct Event: Equatable {
        var start: Date
        var duration: TimeInterval
    }

    var phone: String?
    var event: Event?
    var website: URL?
    var email: URL?
    var address: String?

    init(record: MemoryRecord) {
        phone = record.phone
        let text = record.ocrText
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.date, .link, .address, .phoneNumber]).rawValue)
        else { return }
        // The detector reads dates relative to today. Only a day still to come is offered (an
        // event that is over needs no calendar entry), which also leaves out a bare time of day
        // ("19:00" alone resolves to today).
        let hours = record.hours.map(Self.squashed) ?? ""
        let tomorrow = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        let whole = NSRange(text.startIndex..., in: text)
        detector.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let matched = String(text[range])
            switch match.resultType {
            case .date:
                // Opening hours are dates to the detector too ("Mon–Fri 9–17"): what the record
                // lists as its hours is not an event.
                // A weekday range alone ("Mon–Fri") has no day number: not a calendar date.
                guard event == nil, let date = match.date, date >= tomorrow, matched.contains(where: \.isNumber),
                      hours.isEmpty || !hours.contains(Self.squashed(matched)) else { return }
                event = Event(start: date, duration: match.duration > 0 ? match.duration : 3600)
            case .link:
                guard let url = match.url else { return }
                if url.scheme == "mailto" {
                    if email == nil { email = url }
                } else if website == nil, url.scheme == "http" || url.scheme == "https" {
                    website = url
                }
            case .address:
                if address == nil { address = matched.replacingOccurrences(of: "\n", with: ", ") }
            case .phoneNumber:
                if phone == nil { phone = match.phoneNumber }
            default:
                break
            }
        }
    }

    private static func squashed(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The system's "new event" editor, filled in from a poster: the user checks it and saves it
/// to their own calendar (nothing is added without them; no calendar permission is needed).
struct CalendarEventSheet: UIViewControllerRepresentable {
    let title: String
    let event: MemoryDetections.Event
    let location: String?
    let notes: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let item = EKEvent(eventStore: store)
        item.title = title
        item.startDate = event.start
        item.endDate = event.start.addingTimeInterval(event.duration)
        item.location = location
        item.notes = notes
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = item
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
