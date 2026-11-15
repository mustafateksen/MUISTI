import Foundation
import Observation
import UIKit

/// Something Muisti wants to bring up by itself.
struct Proposal: Sendable {
    var source = "agent"
    var topic: String
    var urgency: Urgency
    var text: String
    var language: String?
    var expectsReply = false
    var frame: URL?
    var intentID: String?
    var recordID: Int64?
    /// After this it is no longer worth saying (the shop is behind, the meeting started).
    var expires: Date?
    /// From a frame that was processed long after it was taken (a background recording).
    var late = false
    /// Something the user started and is waiting for (turn-by-turn directions): spoken whatever
    /// the daily budget and the gap say. Quiet hours, mutes and the main switch still apply.
    var expected = false
    /// A reminder the user asked for, or one whose set time or place has come: never held back
    /// as "said already" (those checks are for what Muisti brings up on its own).
    var userAsked = false
}

/// The one gate everything Muisti says unasked goes through — safety warnings and agent
/// notes alike. It decides how loudly (nothing / a notification / a short sound / a spoken
/// sentence) and when, from rules written here, not by the model:
/// - Muisti may be talkative: the daily budget and the minimum gap for spoken interventions
///   that are not about safety are loose by default (40 a day, 2 minutes) and the user's to set;
/// - quiet hours, muted topics ("don't tell me this again"), a pause per topic;
/// - bounded deferral: something that can wait is held while the user is driving, and said at
///   the next quiet moment or dropped to a notification when its time is up;
/// - a topic the user keeps dismissing is brought up one step more quietly.
/// Safety warnings are always spoken. Every decision is logged, the silent ones too.
@Observable
@MainActor
final class InterventionPolicy {
    private let store: AgentStore
    private let settings: AgentSettings
    private(set) var recent: [Intervention] = []
    private(set) var mutes: [Mute] = []

    /// Speaks through the glasses (`VoiceAssistant.announce`); waits its turn if the user is talking.
    @ObservationIgnored var speak: (_ text: String, _ language: String?, _ expectsReply: Bool, _ frame: URL?, _ urgent: Bool) async -> Void = { _, _, _, _, _ in }
    @ObservationIgnored var chime: () -> Void = {}
    @ObservationIgnored var notify: (_ text: String, _ intentID: String?, _ interventionID: Int64) async -> Void = { _, _, _ in }
    @ObservationIgnored var activity: () -> MotionActivityKind = { .unknown }

    @ObservationIgnored private var held: [(proposal: Proposal, since: Date, id: Int64)] = []
    /// The last thing actually delivered (spoken, chimed or notified): what "not now" and
    /// "don't tell me this again" refer to.
    private(set) var lastDelivered: Intervention?

    static let topicPause: TimeInterval = 15 * 60
    /// Two of Muisti's own remarks this alike are the same remark.
    static let sameRemark = 0.55
    static let sameRemarkWithin: TimeInterval = 3 * 3600

    /// How alike two sentences are: shared words over all words (0…1), ignoring case and
    /// very short words. Language-independent; used only to stop a remark being repeated.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
    static let holdTimely: TimeInterval = 120
    static let holdUseful: TimeInterval = 300

    init(store: AgentStore, settings: AgentSettings) {
        self.store = store
        self.settings = settings
        Task { await reload() }
    }

    func reload() async {
        recent = await store.interventions(since: Date().addingTimeInterval(-7 * 86_400))
        mutes = await store.mutes()
    }

    func isMuted(_ topic: String, intentID: String? = nil) -> Bool {
        mutes.contains { $0.topic == topic || (intentID != nil && $0.topic == "intent:\(intentID!)") }
    }

    /// Decides and delivers. Returns how it was delivered.
    @discardableResult
    func submit(_ p: Proposal, now: Date = Date()) async -> InterventionLevel {
        let (level, reason) = decide(p, now: now)
        var entry = Intervention(at: now, source: p.source, topic: p.topic, urgency: p.urgency, level: level, text: p.text,
                                 language: p.language, intentID: p.intentID, recordID: p.recordID, reason: reason)
        // Can wait and the user is driving: held for the next quiet moment (`release`).
        if level >= .chime, p.urgency != .safety, !p.expected, activity() == .automotive {
            entry.reason = "held: the user is in a vehicle"
            entry.id = await store.insert(entry)
            held.append((p, now, entry.id))
            Trace.note("agent held [\(p.topic)] \(p.text.prefix(70))")
            await reload()
            return level
        }
        entry.id = await store.insert(entry)
        await deliver(p, level: level, entry: entry)
        await reload()
        return level
    }

    /// Called on every agent tick: says what was held once the user is no longer driving, or
    /// lets it go quietly when it has waited too long.
    func release(now: Date = Date()) async {
        guard !held.isEmpty else { return }
        let driving = activity() == .automotive
        var keep: [(proposal: Proposal, since: Date, id: Int64)] = []
        for item in held {
            let limit = item.proposal.urgency == .timely ? Self.holdTimely : Self.holdUseful
            let expired = item.proposal.expires.map { now > $0 } ?? false
            if expired {
                await store.setLevel(item.id, .silent, reason: "held, then no longer relevant")
                await store.setOutcome(item.id, .expired)
            } else if !driving || now.timeIntervalSince(item.since) > limit {
                let level: InterventionLevel = driving ? .notification : decide(item.proposal, now: now).level
                await store.setLevel(item.id, level, reason: driving ? "held too long: notification" : "said after the drive")
                var entry = Intervention(at: now, source: item.proposal.source, topic: item.proposal.topic, urgency: item.proposal.urgency,
                                         level: level, text: item.proposal.text, intentID: item.proposal.intentID)
                entry.id = item.id
                await deliver(item.proposal, level: level, entry: entry)
            } else {
                keep.append(item)
            }
        }
        held = keep
        await reload()
    }

    private func decide(_ p: Proposal, now: Date) -> (level: InterventionLevel, reason: String?) {
        if p.urgency == .safety { return (.spoken, nil) }
        guard settings.enabled else { return (.silent, "the agent is switched off") }
        if isMuted(p.topic, intentID: p.intentID) { return (.silent, "muted by the user") }
        if let expires = p.expires, now > expires { return (.silent, "no longer relevant") }
        var level: InterventionLevel
        switch p.urgency {
        case .safety, .timely: level = .spoken
        case .useful: level = .chime
        case .fyi: return (.silent, nil)
        }
        var reason: String?
        if p.late { return (min(level, .notification), "from a frame processed later") }
        // The same topic a moment ago: once is enough. (Before, anything tied to a note of
        // Muisti's own skipped this and came back every few minutes.) What the user is waiting
        // for (`expected`) is not held back.
        if !p.expected, !p.userAsked, let last = recent.first(where: { $0.topic == p.topic && $0.level >= .notification }),
           now.timeIntervalSince(last.at) < Self.topicPause {
            return (.silent, "same topic \(Int(now.timeIntervalSince(last.at) / 60)) min ago")
        }
        // Nearly the same sentence as one already said: nothing new to hear.
        if !p.expected, !p.userAsked, let twin = recent.first(where: { $0.level >= .notification && now.timeIntervalSince($0.at) < Self.sameRemarkWithin
                                                          && Self.similarity($0.text, p.text) >= Self.sameRemark }) {
            return (.silent, "said nearly the same at \(QueryEngine.clock(twin.at))")
        }
        // A topic the user keeps turning down is brought up one step more quietly.
        let lastOutcomes = recent.filter { $0.topic == p.topic && $0.outcome != nil }.prefix(3).compactMap(\.outcome)
        if lastOutcomes.count == 3, lastOutcomes.allSatisfy({ $0 == .dismissed || $0 == .snoozed }) {
            level = InterventionLevel(rawValue: level.rawValue - 1) ?? .silent
            reason = "turned down three times in a row"
        }
        guard level == .spoken else { return (level, reason) }
        if settings.isQuiet(now) { return (.notification, "quiet hours") }
        if p.expected { return (.spoken, reason) }
        let today = Calendar.current.startOfDay(for: now)
        let spoken = recent.filter { $0.level == .spoken && $0.urgency != .safety && $0.at >= today }
        if spoken.count >= settings.dailySpokenBudget { return (.notification, "today's spoken budget (\(settings.dailySpokenBudget)) is used up") }
        if let last = spoken.first, now.timeIntervalSince(last.at) < Double(settings.minGapMinutes) * 60 {
            return (.chime, "spoke \(Int(now.timeIntervalSince(last.at) / 60)) min ago")
        }
        return (level, reason)
    }

    private func deliver(_ p: Proposal, level: InterventionLevel, entry: Intervention) async {
        Trace.note("agent [\(p.source)/\(p.topic)] \(p.urgency.rawValue) → level \(level.rawValue)\(entry.reason.map { " (\($0))" } ?? ""): \(p.text.prefix(80))")
        Log.pipeline.info("intervention [\(p.source, privacy: .public)/\(p.topic, privacy: .public)] level \(level.rawValue) \(entry.reason ?? "-", privacy: .public): \(p.text, privacy: .public)")
        guard level > .silent else { return }
        lastDelivered = entry
        switch level {
        case .spoken:
            // Not in front of the user: the notification keeps it on the lock screen too.
            // (Safety warnings post their own.)
            if p.source != "safety", UIApplication.shared.applicationState != .active {
                await notify(p.text, p.intentID, entry.id)
            }
            await speak(p.text, p.language, p.expectsReply, p.frame, p.urgency == .safety)
        case .chime:
            chime()
            await notify(p.text, p.intentID, entry.id)
        case .notification:
            await notify(p.text, p.intentID, entry.id)
        case .silent:
            break
        }
    }

    // MARK: What the user made of it

    func setOutcome(_ outcome: Intervention.Outcome, id: Int64? = nil) async {
        guard let id = id ?? lastDelivered?.id else { return }
        await store.setOutcome(id, outcome)
        await reload()
    }

    func mute(topic: String, minutes: Int?) async {
        await store.save(Mute(topic: topic, until: minutes.map { Date().addingTimeInterval(Double($0) * 60) }))
        await reload()
    }

    func unmute(_ topic: String) async {
        await store.deleteMute(topic)
        await reload()
    }

    /// How many spoken, non-safety interventions today (for the settings screen and the log).
    func spokenToday(now: Date = Date()) -> Int {
        let today = Calendar.current.startOfDay(for: now)
        return recent.filter { $0.level == .spoken && $0.urgency != .safety && $0.at >= today }.count
    }
}
