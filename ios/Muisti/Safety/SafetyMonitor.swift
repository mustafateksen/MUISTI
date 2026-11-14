import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Commands the answer model can give for Muisti Turva (see `SafetyPrompts.answerRules`).
enum SafetyCommand: Sendable, Equatable {
    case createRule(SafetyRule)
    case confirm
    case cancel
    case deleteRule(String)
    case logEvent(object: String, kind: SafetyEventKind, value: String)
    case leaving
    case arriving
    case setHome
    case snooze
}

/// Muisti Turva: watches frames for the objects in the user's own rules, keeps their state
/// (two "on" readings to call something on, one "off" to call it off), and warns when a rule's
/// trigger and condition hold — saying what was seen and when, with the frame.
///
/// Rules are evaluated here, in code. The model only turns speech into rules (answer call) and
/// reads watched objects off frames (`SafetyPrompts.observe…`).
@Observable
@MainActor
final class SafetyMonitor {
    struct Tuning: Sendable {
        var homeHandsEvery: TimeInterval = 5      // at home, hands in view
        var homeEvery: TimeInterval = 30          // at home, hands not in view
        var labelEvery: TimeInterval = 8          // allergen rules: frames with a lot of text
        var awayEvery: TimeInterval = 20          // event rules away from home
        var maxPerMinute = 20
        var onReadingsNeeded = 2
        var staleAfter: TimeInterval = 12 * 3600
        var homeRadius: Double = 80
        var leaveDebounce: TimeInterval = 30 * 60
        var snooze: TimeInterval = 30 * 60
        var confirmWindowMinutes = 120           // a medicine seen in hand this long around its time
    }

    private(set) var rules: [SafetyRule] = []
    private(set) var states: [ObjectState] = []
    private(set) var alerts: [SafetyAlert] = []
    private(set) var pending: SafetyPending?
    private(set) var home: CLLocationCoordinate2D?
    private(set) var lastRoom: (room: String, at: Date)?
    private(set) var lastObservationText = "—"
    var tuning = Tuning()

    let store: SafetyStore
    @ObservationIgnored private let ai: NemotronClient
    @ObservationIgnored private let location: LocationProvider
    /// Speaks an alert or question through the glasses (set by the controller).
    @ObservationIgnored var announce: (_ text: String, _ language: String?, _ expectsReply: Bool, _ frame: URL?) async -> Void = { _, _, _, _ in }

    @ObservationIgnored private var lastSent: Date?
    @ObservationIgnored private var sentTimes: [Date] = []
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var snoozedUntil: [String: Date] = [:]
    @ObservationIgnored private var lastAlertRule: String?
    @ObservationIgnored private var lastLeaveAt: Date?
    @ObservationIgnored private var wasHome: Bool?
    @ObservationIgnored private var askedConfirm: [String: Date] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?

    private static let homeKey = "safety.home"

    init(store: SafetyStore, ai: NemotronClient, location: LocationProvider) {
        self.store = store
        self.ai = ai
        self.location = location
        if let saved = UserDefaults.standard.array(forKey: Self.homeKey) as? [Double], saved.count == 2 {
            home = CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
        }
        Task { await reload() }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.tick()
            }
        }
    }

    isolated deinit { timer?.cancel() }

    func reload() async {
        await store.purge()
        rules = await store.rules()
        states = await store.states().map(staled)
        alerts = await store.alerts()
    }

    var watched: [String] {
        var all: [String] = []
        for rule in rules where rule.enabled {
            for o in rule.watchedObjects where !all.contains(o) { all.append(o) }
        }
        return all
    }

    var watchedAllergens: [String] {
        Array(Set(rules.filter(\.enabled).flatMap { $0.condition.allergens ?? [] })).sorted()
    }

    // MARK: Zones

    enum Zone: String { case home, away, unknown }

    var zone: Zone {
        guard let home, let fix = location.freshFix(maxAge: 120) else { return .unknown }
        let d = MemoryStore.haversine(home.latitude, home.longitude, fix.latitude, fix.longitude)
        let slack = min(fix.accuracy, 100)
        if d <= tuning.homeRadius + slack { return .home }
        if d > tuning.homeRadius + slack + 50 { return .away }
        return .unknown
    }

    /// At home: the location says so, or (no home set / no fix) the last frames were indoors.
    var atHome: Bool {
        switch zone {
        case .home: return true
        case .away: return false
        case .unknown:
            guard let lastRoom, Date().timeIntervalSince(lastRoom.at) < 30 * 60 else { return true }
            return !["outside", "store"].contains(lastRoom.room)
        }
    }

    func setHomeHere() -> Bool {
        guard let fix = location.freshFix(maxAge: 300) ?? location.latest else { return false }
        home = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        UserDefaults.standard.set([fix.latitude, fix.longitude], forKey: Self.homeKey)
        wasHome = true
        return true
    }

    // MARK: Frames

    /// Called for every captured frame. Cheap gates first; at most one model call at a time.
    func consider(_ frame: CapturedFrame) {
        let watched = self.watched
        guard !watched.isEmpty || !watchedAllergens.isEmpty, !inFlight else { return }
        let now = Date()
        sentTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard sentTimes.count < tuning.maxPerMinute else { return }
        let home = atHome
        let since = lastSent.map { now.timeIntervalSince($0) } ?? .infinity
        let hasAllergenRules = !watchedAllergens.isEmpty
        let hasAwayRules = rules.contains { $0.enabled && $0.trigger.type == .event && $0.trigger.object != "label" }
        // Fast path decided without any image work.
        if home, since < tuning.homeHandsEvery { return }
        if !home, !hasAllergenRules, !hasAwayRules { return }
        if !home, since < min(tuning.labelEvery, tuning.awayEvery) { return }
        inFlight = true
        let jpeg = frame.jpeg
        let tuning = self.tuning
        let allergens = watchedAllergens
        Task {
            defer { self.inFlight = false }
            let prepared = await Task.detached(priority: .utility) { () -> (SafetyFrame.Prepared?, Bool) in
                let hands = SafetyFrame.handsVisible(jpeg)
                // At home without hands, or away: only every so often (cheap check above).
                return (SafetyFrame.prepare(jpeg), hands)
            }.value
            guard let copy = prepared.0 else { return }
            let hands = prepared.1
            let due: Bool
            if home {
                due = hands ? since >= tuning.homeHandsEvery : since >= tuning.homeEvery
            } else {
                let label = hasAllergenRules && copy.lineCount >= 4 && since >= tuning.labelEvery
                due = label || (hasAwayRules && since >= tuning.awayEvery)
            }
            guard due else { return }
            self.lastSent = Date()
            self.sentTimes.append(Date())
            await self.observe(copy, frame: frame, watched: watched, allergens: allergens)
        }
    }

    private func observe(_ copy: SafetyFrame.Prepared, frame: CapturedFrame, watched: [String], allergens: [String]) async {
        let observation: SafetyObservation
        do {
            observation = try await ai.chatJSON(SafetyObservation.self, system: SafetyPrompts.observeSystem,
                                                user: SafetyPrompts.observeUser(watched: watched, allergens: allergens, ocr: copy.ocr),
                                                image: .init(jpeg: copy.jpeg), jsonSchema: SafetyPrompts.observeSchema,
                                                schemaName: "observation", maxTokens: 500, temperature: 0.2, background: true)
        } catch {
            Log.pipeline.info("safety observe failed: \(String(describing: error), privacy: .public)")
            return
        }
        let file = await store.saveFrame(copy.jpeg)
        await apply(observation, at: frame.capturedAt, frameFile: file, latitude: frame.latitude, longitude: frame.longitude)
    }

    // MARK: State machine

    /// Applies one frame's reading. Public for the scenario evaluation (no network).
    func apply(_ obs: SafetyObservation, at: Date, frameFile: String?, latitude: Double? = nil, longitude: Double? = nil) async {
        let summary = obs.objects.filter(\.visible).map { "\($0.name)=\($0.state)" } + obs.actions.map { "\($0.object):\($0.action)" }
        lastObservationText = "\(obs.room) · " + (summary.isEmpty ? "nothing watched in view" : summary.joined(separator: ", "))
        Log.pipeline.info("safety: \(self.lastObservationText, privacy: .public)")
        let zoneName = zone.rawValue
        func event(_ kind: SafetyEventKind, _ object: String?, _ value: String?, source: SafetySource = .vision, detail: String? = nil) -> SafetyEvent {
            SafetyEvent(at: at, kind: kind, object: object, value: value, confidence: nil, source: source, frameFile: frameFile,
                        latitude: latitude, longitude: longitude, zone: zoneName, detail: detail)
        }

        // Room: leaving home seen through the glasses (indoors → outside).
        if obs.room != "unknown" {
            let previous = lastRoom
            lastRoom = (obs.room, at)
            if obs.room == "outside", let previous, previous.room != "outside", previous.room != "store",
               at.timeIntervalSince(previous.at) < 15 * 60 {
                await trigger(contextEvent: "left_home", source: .vision, at: at)
            }
        }

        var triggered: [(object: String, state: String)] = []
        for o in obs.objects where o.visible && o.state != "unknown" {
            await observe(object: o.name, state: o.state, at: at, frameFile: frameFile, place: o.location_hint, source: .vision)
            if ["in_hand", "placed"].contains(o.state) {
                await store.insert(event(.object_seen, o.name, o.state, detail: o.location_hint))
            }
            triggered.append((o.name, o.state))
        }
        for a in obs.actions {
            await action(a.action, on: a.object, at: at, frameFile: frameFile, source: .vision)
        }
        if let label = obs.label, label.ingredients_visible {
            let found = label.allergens_found.joined(separator: ", ")
            await store.insert(event(.label, "label", found.isEmpty ? "none" : found,
                                     detail: [label.product, label.evidence].compactMap { $0 }.joined(separator: " · ")))
            await fireEventRules(object: "label", state: nil, at: at, label: label, frameFile: frameFile)
        }
        for (object, state) in triggered {
            await fireEventRules(object: object, state: state, at: at, label: nil, frameFile: frameFile)
            if state == "in_hand" { await maybeAskToConfirm(object: object, at: at, frameFile: frameFile) }
        }
        states = await store.states().map(staled)
    }

    /// One reading of an object's state. "on" needs `onReadingsNeeded` readings in a row; any
    /// other state counts at once (missing a turn-off is worse than a late "on").
    func observe(object: String, state: String, at: Date, frameFile: String?, place: String?, source: SafetySource) async {
        var st = await currentState(object) ?? ObjectState(object: object, state: "unknown", since: at, lastSeen: at,
                                                            lastStateSeen: at, evidenceFrame: frameFile, source: source, place: place)
        st.lastSeen = at
        if let place { st.place = place }
        if state == "on" {
            if st.state == "on" {
                st.lastStateSeen = at
                st.evidenceFrame = frameFile ?? st.evidenceFrame
            } else {
                st.pendingOnCount += 1
                if st.pendingOnCount >= tuning.onReadingsNeeded || source != .vision {
                    st = ObjectState(object: object, state: "on", since: at, lastSeen: at, lastStateSeen: at,
                                     evidenceFrame: frameFile ?? st.evidenceFrame, pendingOnCount: 0, source: source, place: st.place)
                    await store.insert(SafetyEvent(at: at, kind: .state, object: object, value: "on", source: source,
                                                   frameFile: frameFile, zone: zone.rawValue))
                }
            }
        } else {
            st.pendingOnCount = 0
            if st.state != state {
                st.state = state
                st.since = at
                st.source = source
                if !["in_hand", "placed"].contains(state) {
                    await store.insert(SafetyEvent(at: at, kind: .state, object: object, value: state, source: source,
                                                   frameFile: frameFile, zone: zone.rawValue))
                }
            }
            st.lastStateSeen = at
            st.evidenceFrame = frameFile ?? st.evidenceFrame
        }
        await store.save(st)
        states = await store.states().map(staled)
    }

    /// An action on an object (seen, or told by the user). Actions that only the user can
    /// confirm (taking a medicine) are kept as candidates until they say yes.
    func action(_ action: String, on object: String, at: Date, frameFile: String?, source: SafetySource) async {
        if action == "took", source == .vision {
            await maybeAskToConfirm(object: object, at: at, frameFile: frameFile)
            return
        }
        await store.insert(SafetyEvent(at: at, kind: .action, object: object, value: action, source: source,
                                       frameFile: frameFile, zone: zone.rawValue))
        switch action {
        case "turned_off": await observe(object: object, state: "off", at: at, frameFile: frameFile, place: nil, source: source)
        case "turned_on": await observe(object: object, state: "on", at: at, frameFile: frameFile, place: nil, source: source)
        case "locked": await observe(object: object, state: "locked", at: at, frameFile: frameFile, place: nil, source: source)
        case "unlocked": await observe(object: object, state: "unlocked", at: at, frameFile: frameFile, place: nil, source: source)
        case "took":
            await rescheduleNotifications()
        default: break
        }
    }

    private func currentState(_ object: String) async -> ObjectState? {
        await store.states().first { $0.object == object }.map(staled)
    }

    /// An "on" not seen for 12 hours is no longer known.
    private func staled(_ st: ObjectState) -> ObjectState {
        guard st.state == "on", Date().timeIntervalSince(st.lastStateSeen) > tuning.staleAfter else { return st }
        var s = st
        s.state = "unknown"
        return s
    }

    // MARK: Confirmation loop

    /// A medicine (an object some schedule rule wants "took" for) seen in hand around its time:
    /// ask once whether it was taken. The answer, not the frame, makes it count.
    private func maybeAskToConfirm(object: String, at: Date, frameFile: String?) async {
        guard pending == nil, askedConfirm[object].map({ at.timeIntervalSince($0) > 20 * 60 }) ?? true else { return }
        let candidates = rules.filter { $0.enabled && $0.condition.object == object && $0.condition.action == "took" }
        guard let rule = candidates.first else { return }
        let taken = await count(action: "took", object: object, since: Calendar.current.startOfDay(for: at))
        // Already taken today: the second-dose rule (if any) speaks; do not ask again.
        guard taken == 0 else { return }
        if let time = rule.trigger.time, let due = Self.today(time, now: at),
           abs(at.timeIntervalSince(due)) > Double(tuning.confirmWindowMinutes) * 60 { return }
        askedConfirm[object] = at
        pending = .action(object: object, action: "took", frame: frameFile, seenAt: at)
        let name = object.split(separator: ":").last.map(String.init) ?? object
        let question = rule.confirmQuestion ?? "Did you take your \(name)?"
        await announce(question, rule.language, true, frameFile.map(store.frameURL))
    }

    // MARK: Commands from the answer model

    /// Runs a command; returns a reply that replaces the model's acknowledgement when Muisti has
    /// something more important to say (a warning on leaving).
    func handle(_ command: SafetyCommand, now: Date = Date()) async -> String? {
        switch command {
        case .createRule(var rule):
            rule.enabled = true
            pending = .rule(rule)
        case .confirm:
            switch pending {
            case .rule(let rule):
                await store.save(rule)
                await reload()
                if rule.trigger.type == .schedule { await requestNotificationPermission() }
                await rescheduleNotifications()
            case .deleteRule(let rule):
                await store.deleteRule(rule.id)
                await reload()
                await rescheduleNotifications()
            case .action(let object, let action, let frame, let seenAt):
                await self.action(action, on: object, at: seenAt, frameFile: frame, source: .user_confirmed)
            case nil:
                break
            }
            pending = nil
        case .cancel:
            pending = nil
        case .deleteRule(let id):
            if let rule = rules.first(where: { $0.id == id }) { pending = .deleteRule(rule) }
        case .logEvent(let spoken, let kind, let value):
            // The user says "Enalapril"; the rule watches "medication:enalapril".
            let object = watched.first { $0 == spoken || $0.hasSuffix(":" + spoken) || spoken.hasSuffix(":" + $0) } ?? spoken
            if kind == .action {
                await action(value, on: object, at: now, frameFile: nil, source: .user_voice)
            } else {
                await observe(object: object, state: value, at: now, frameFile: nil, place: nil, source: .user_voice)
                await store.insert(SafetyEvent(at: now, kind: .state, object: object, value: value, source: .user_voice))
            }
            states = await store.states().map(staled)
        case .leaving:
            let spoken = await trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
            return spoken.isEmpty ? nil : spoken.joined(separator: " ")
        case .arriving:
            await trigger(contextEvent: "arrived_home", source: .user_voice, at: now)
        case .setHome:
            if !setHomeHere() { return nil }
        case .snooze:
            if let rule = lastAlertRule { snoozedUntil[rule] = now.addingTimeInterval(tuning.snooze) }
            if let last = alerts.first { await store.respond(alert: last.id, .snoozed) }
            alerts = await store.alerts()
        }
        return nil
    }

    func setEnabled(_ rule: SafetyRule, _ enabled: Bool) async {
        var r = rule
        r.enabled = enabled
        await store.save(r)
        await reload()
        await rescheduleNotifications()
    }

    func delete(_ rule: SafetyRule) async {
        await store.deleteRule(rule.id)
        await reload()
        await rescheduleNotifications()
    }

    func respond(_ alert: SafetyAlert, _ response: SafetyAlert.Response) async {
        await store.respond(alert: alert.id, response)
        if response == .snoozed { snoozedUntil[alert.ruleID] = Date().addingTimeInterval(tuning.snooze) }
        alerts = await store.alerts()
    }

    // MARK: Triggers

    /// Leaving / arriving home. Returns the warnings (spoken too unless `speak` is false).
    @discardableResult
    func trigger(contextEvent: String, source: SafetySource, at: Date, speak: Bool = true) async -> [String] {
        if contextEvent == "left_home" {
            if let last = lastLeaveAt, at.timeIntervalSince(last) < tuning.leaveDebounce, source == .vision { return [] }
            lastLeaveAt = at
        }
        await store.insert(SafetyEvent(at: at, kind: .context, object: nil, value: contextEvent, source: source, zone: zone.rawValue))
        var said: [String] = []
        for rule in rules where rule.enabled && rule.trigger.type == .context && rule.trigger.event == contextEvent {
            if let text = await fire(rule, at: at, label: nil, speak: speak) { said.append(text) }
        }
        return said
    }

    private func fireEventRules(object: String, state: String?, at: Date, label: SafetyObservation.Label?, frameFile: String?) async {
        for rule in rules where rule.enabled && rule.trigger.type == .event && rule.trigger.object == object {
            if let wanted = rule.trigger.state, wanted != state { continue }
            await fire(rule, at: at, label: label, speak: true, frameFile: frameFile)
        }
    }

    /// Every 30 s: schedules, inactivity, and leaving / arriving by location.
    func tick(now: Date = Date()) async {
        // Location transition home ↔ away.
        let z = zone
        if z != .unknown {
            let isHome = z == .home
            if let wasHome, wasHome != isHome {
                await trigger(contextEvent: isHome ? "arrived_home" : "left_home", source: .system, at: now)
            }
            wasHome = isHome
        }
        for rule in rules where rule.enabled {
            switch rule.trigger.type {
            case .schedule:
                guard let time = rule.trigger.time, let start = Self.today(time, now: now) else { continue }
                let due = start.addingTimeInterval(Double(rule.trigger.grace_min ?? 0) * 60)
                guard now >= due, now.timeIntervalSince(due) < 3 * 3600 else { continue }
                if let handled = await store.lastFired(rule.id), handled >= due { continue }
                await store.setLastFired(rule.id, now)
                await fire(rule, at: now, label: nil, speak: true, ignoreCooldown: true)
            case .inactivity:
                guard let object = rule.trigger.object, let minutes = rule.trigger.minutes,
                      let st = await currentState(object), st.state == (rule.trigger.state ?? "on"),
                      now.timeIntervalSince(st.lastSeen) >= Double(minutes) * 60, atHome else { continue }
                await fire(rule, at: now, label: nil, speak: true)
            default:
                break
            }
        }
    }

    // MARK: Rule evaluation

    /// Condition check + alert. Returns the spoken text if the rule fired.
    @discardableResult
    private func fire(_ rule: SafetyRule, at: Date, label: SafetyObservation.Label?, speak: Bool,
                      frameFile: String? = nil, ignoreCooldown: Bool = false) async -> String? {
        if let until = snoozedUntil[rule.id], at < until { return nil }
        if !ignoreCooldown, let last = alerts.first(where: { $0.ruleID == rule.id }),
           at.timeIntervalSince(last.at) < Double(rule.cooldown_min) * 60 { return nil }
        guard let filled = await evaluate(rule, at: at, label: label) else { return nil }
        let text = Self.fill(rule.message, with: filled.values)
        let alert = SafetyAlert(at: at, ruleID: rule.id, message: text, evidenceFrame: filled.frame ?? frameFile, severity: rule.severity)
        await store.insert(alert)
        await store.setLastFired(rule.id, at)
        alerts = await store.alerts()
        lastAlertRule = rule.id
        Log.pipeline.info("safety alert [\(rule.id, privacy: .public)]: \(text, privacy: .public)")
        // Low severity: phone only (notification / Safety tab), never spoken.
        if speak, rule.severity != .low {
            await announce(text, rule.language, false, alert.evidenceFrame.map(store.frameURL))
        }
        await notifyIfBackground(text)
        return text
    }

    struct Filled: Sendable { var values: [String: String] = [:]; var frame: String? }

    /// Whether the rule's condition holds now, with the values for its message.
    func evaluate(_ rule: SafetyRule, at: Date, label: SafetyObservation.Label? = nil) async -> Filled? {
        let c = rule.condition
        var filled = Filled()
        if let object = c.object, let wanted = c.last_state {
            guard let st = await currentState(object), st.state == wanted else { return nil }
            if let notFollowed = c.not_followed_by, st.state == notFollowed { return nil }
            filled.values["last_seen_time"] = Self.clock(st.lastStateSeen)
            filled.values["place"] = st.place ?? ""
            filled.frame = st.evidenceFrame
        }
        if let action = c.action {
            let since = c.within_min.map { at.addingTimeInterval(-Double($0) * 60) } ?? Calendar.current.startOfDay(for: at)
            let events = await confirmedActions(action, object: c.object, since: since)
            if let atLeast = c.count_at_least {
                guard events.count >= atLeast, let last = events.first else { return nil }
                filled.values["action_time"] = Self.clock(last.at)
                filled.frame = filled.frame ?? last.frameFile
            } else {
                guard events.isEmpty else { return nil }
            }
        }
        if let minutes = c.seen_within_min, let object = c.object {
            let seen = await store.events(since: at.addingTimeInterval(-Double(minutes) * 60), object: object, kind: .object_seen)
            // Seen at home and not picked up since.
            guard let last = seen.first, last.value == "placed" else { return nil }
            filled.values["last_seen_time"] = Self.clock(last.at)
            filled.values["place"] = last.detail ?? ""
            filled.frame = last.frameFile
        }
        if let wanted = c.allergens, !wanted.isEmpty {
            guard let label else { return nil }
            let hits = label.allergens_found.filter { found in wanted.contains { $0 == found || found.contains($0) || $0.contains(found) } }
            guard !hits.isEmpty else { return nil }
            filled.values["allergens"] = hits.joined(separator: ", ")
            filled.values["product"] = label.product ?? ""
        }
        return filled
    }

    private func count(action: String, object: String, since: Date) async -> Int {
        await confirmedActions(action, object: object, since: since).count
    }

    /// Actions that count: everything the user told or confirmed, and what was seen for
    /// actions that need no confirmation.
    private func confirmedActions(_ action: String, object: String?, since: Date) async -> [SafetyEvent] {
        await store.events(since: since, object: object, kind: .action, value: action)
            .filter { action != "took" || $0.source != .vision }
    }

    static func fill(_ template: String, with values: [String: String]) -> String {
        var text = template
        for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        // Unfilled placeholders never reach the user.
        while let open = text.range(of: "{"), let close = text.range(of: "}", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func today(_ hhmm: String, now: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
    }

    // MARK: Prompt context

    /// Rules, states and the last day of the safety log, for the answer model.
    func promptContext(now: Date = Date()) async -> String {
        let events = await store.events(since: now.addingTimeInterval(-24 * 3600), limit: 30)
        let ruleLines = rules.map { "- id \($0.id) (\($0.enabled ? "on" : "off")): \($0.summary)" }
        let stateLines = states.map { st in
            "- \(st.object): \(st.state) since \(QueryEngine.promptTime(st.since)), last seen in that state \(QueryEngine.promptTime(st.lastStateSeen))"
                + (st.place.map { ", \($0)" } ?? "") + " (source: \(st.source.rawValue))"
        }
        let eventLines = events.map { e in
            "- event \(e.id) · \(QueryEngine.promptTime(e.at)) · \(e.kind.rawValue) · \(e.object ?? "-") = \(e.value ?? "-")"
                + (e.detail.map { " · \($0)" } ?? "") + " (source: \(e.source.rawValue)\(e.frameFile == nil ? "" : ", has frame"))"
        }
        return """
        Safety rules:
        \(ruleLines.isEmpty ? "(none)" : ruleLines.joined(separator: "\n"))
        Watched objects, last known state:
        \(stateLines.isEmpty ? "(none seen yet)" : stateLines.joined(separator: "\n"))
        Safety log, last 24 hours (newest first):
        \(eventLines.isEmpty ? "(empty)" : eventLines.joined(separator: "\n"))
        Last warning: \(alerts.first.map { "\(QueryEngine.promptTime($0.at)): \($0.message)" } ?? "(none)")
        Home location set: \(home == nil ? "no" : "yes"); user now: \(zone.rawValue)
        Pending yes/no: \(pending?.prompt ?? "(nothing)")
        """
    }

    func frames(forEvents ids: [Int64]) async -> [URL] {
        guard !ids.isEmpty else { return [] }
        let events = await store.events(since: Date().addingTimeInterval(-30 * 86_400), limit: 500)
        return events.filter { ids.contains($0.id) }.compactMap(\.frameFile).map(store.frameURL)
    }

    // MARK: Notifications

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// One local notification per schedule rule at its next check time, so a reminder reaches
    /// the user even when Muisti is closed. Removed for today once the action is logged.
    func rescheduleNotifications(now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("safety.") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for rule in rules where rule.enabled && rule.trigger.type == .schedule {
            guard let time = rule.trigger.time, let start = Self.today(time, now: now) else { continue }
            var due = start.addingTimeInterval(Double(rule.trigger.grace_min ?? 0) * 60)
            let doneToday = await evaluate(rule, at: now) == nil && now < due.addingTimeInterval(3 * 3600)
            if due <= now || doneToday { due = Calendar.current.date(byAdding: .day, value: 1, to: due) ?? due }
            let content = UNMutableNotificationContent()
            content.title = "Muisti"
            content.body = Self.fill(rule.message, with: [:])
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            let request = UNNotificationRequest(identifier: "safety.\(rule.id)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    private func notifyIfBackground(_ text: String) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Muisti"
        content.body = text
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Forget

    func forget(since: Date) async {
        await store.delete(since: since)
        await reload()
    }
}
