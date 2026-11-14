import CoreLocation
import Foundation
import UserNotifications

/// The agent's phone notifications: what it says when it should not speak, and the reminders
/// that must arrive even when Muisti is closed (a time, or a place the phone can watch for).
/// Each carries three actions — done, later, don't tell me again — which come back through
/// `onAction`.
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Action: String, Sendable { case done = "muisti.done", later = "muisti.later", never = "muisti.never", opened = "muisti.opened" }

    static let category = "muisti.agent"
    /// (action, intent id, intervention id)
    var onAction: (@Sendable (Action, String?, Int64?) async -> Void)?

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: Action.done.rawValue, title: String(localized: "Done")),
            UNNotificationAction(identifier: Action.later.rawValue, title: String(localized: "Later")),
            UNNotificationAction(identifier: Action.never.rawValue, title: String(localized: "Don't tell me again"), options: [.destructive]),
        ]
        center.getNotificationCategories { existing in
            let ours = UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: [])
            center.setNotificationCategories(existing.filter { $0.identifier != Self.category }.union([ours]))
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func content(_ text: String, intentID: String?, interventionID: Int64?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Muisti"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = category
        var info: [String: Any] = [:]
        if let intentID { info["intent"] = intentID }
        if let interventionID { info["intervention"] = interventionID }
        content.userInfo = info
        return content
    }

    /// Shown now.
    static func post(_ text: String, intentID: String?, interventionID: Int64?) async {
        let request = UNNotificationRequest(identifier: "agent.now.\(interventionID ?? Int64(Date().timeIntervalSince1970))",
                                            content: content(text, intentID: intentID, interventionID: interventionID), trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The system-side copy of an intent's cue, so it arrives with Muisti closed: its time,
    /// and/or arriving at its place. Replaces what was scheduled for the intent before.
    static func schedule(_ intent: Intent, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["agent.time.\(intent.id)", "agent.place.\(intent.id)"])
        guard intent.status == .open else { return }
        let text = intent.say ?? intent.text
        if let due = intent.cue.nextDue(after: intent.firedAt ?? now), due > now {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            let request = UNNotificationRequest(identifier: "agent.time.\(intent.id)", content: content(text, intentID: intent.id, interventionID: nil),
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
        if intent.kind != .destination, intent.kind != .parking, let coordinate = intent.coordinate {
            let region = CLCircularRegion(center: coordinate, radius: 120, identifier: "agent.place.\(intent.id)")
            region.notifyOnEntry = true
            region.notifyOnExit = false
            let request = UNNotificationRequest(identifier: "agent.place.\(intent.id)", content: content(text, intentID: intent.id, interventionID: nil),
                                                trigger: UNLocationNotificationTrigger(region: region, repeats: false))
            try? await center.add(request)
        }
    }

    static func cancel(intentID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["agent.time.\(intentID)", "agent.place.\(intentID)"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent.time.\(intentID)", "agent.place.\(intentID)"])
    }

    /// The scheduled copy is dropped while Muisti itself is running and will say it (no double
    /// reminder); it is put back when the app goes to the background.
    static func pendingIDs() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.category else { return }
        let info = response.notification.request.content.userInfo
        let action = Action(rawValue: response.actionIdentifier) ?? .opened
        let intent = info["intent"] as? String
        let intervention = (info["intervention"] as? NSNumber)?.int64Value
        await onAction?(action, intent, intervention)
    }
}
