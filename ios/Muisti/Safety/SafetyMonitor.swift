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
        var labelEvery: TimeInterval = 6          // allergen rules: a package check this often
        var awayEvery: TimeInterval = 20          // event rules away from home
        var maxPerMinute = 60
        var onReadingsNeeded = 2
        var staleAfter: TimeInterval = 12 * 3600
        var homeRadius: Double = 80
        var leaveDebounce: TimeInterval = 30 * 60
        var snooze: TimeInterval = 30 * 60
        var confirmWindowMinutes = 120           // a medicine seen in hand this long around its time
        var productCooldownMinutes = 3.0          // the same product warns again after this
        // Enriched record ↔ rule (see checkEnriched for the calibration).
        var ruleDirectLogit = -2.85               // rerank at or above, and …
        var ruleDirectCosine = 0.20               // … embedding at or above: warn at once
        var ruleDirectCosineAlone = 0.27          // no reranker: embedding alone to warn at once
        var ruleGateLogit = -3.1                  // below both gates: not about the rule
        var ruleGateCosine = 0.22
    }

    private(set) var rules: [SafetyRule] = []
    private(set) var states: [ObjectState] = []
    private(set) var alerts: [SafetyAlert] = []
    private(set) var pending: SafetyPending?
    private(set) var home: CLLocationCoordinate2D?
    private(set) var lastRoom: (room: String, at: Date)?
    private(set) var lastObservationText = "—"
    var tuning = Tuning()
    @ObservationIgnored private var recentTexts: [(words: Set<String>, at: Date)] = []
    @ObservationIgnored private var productAlerts: [String: Date] = [:]

    let store: SafetyStore
    @ObservationIgnored private let ai: NemotronClient
    @ObservationIgnored private let location: LocationProvider
    /// Hazards flagged by the frame model on its own, without any rule (setting).
    @ObservationIgnored var autoHazards: () -> Bool = { true }
    /// Speaks an alert or question through the glasses (set by the controller).
    @ObservationIgnored var announce: (_ text: String, _ language: String?, _ expectsReply: Bool, _ frame: URL?) async -> Void = { _, _, _, _ in }

    /// The last few frames at home (raw, in memory only, at most 12 s old): when a look is sent
    /// while the user's hands are in view, the ones just before it go along as a time strip, so
    /// the model can see something being done (a knob turned, a pill taken), not just a state.
    @ObservationIgnored private var recentFrames: [(jpeg: Data, at: Date)] = []
    /// Frames of one moment sent together: 8 as pictures of their own where the host takes
    /// several, the last 4 on one sheet elsewhere.
    static let stripFrames = 8
    static let sheetFrames = 4
    static let stripSeconds: TimeInterval = 12
    @ObservationIgnored private var lastSent: Date?
    @ObservationIgnored private var sentTimes: [Date] = []
    /// Looks in flight, by what they look for (the watched things and allergens, at home or
    /// away). A frame that arrives while its kind of look is running is not dropped: it waits,
    /// a newer one of the same kind takes its place (merged), and it is looked at as soon as
    /// the running look is done. Looks for different things run side by side.
    @ObservationIgnored private var looksInFlight: Set<Int> = []
    @ObservationIgnored private var waitingFrames: [Int: CapturedFrame] = [:]
    /// Where merged and expired frames are written down (kind, state, detail).
    @ObservationIgnored var eventLog: (@Sendable (String, String, String) async -> Void)?
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

    /// Set when a first "on" reading waits for its confirming frame.
    @ObservationIgnored private var confirmSoon: Date?

    /// Called for every captured frame. Cheap gates first; at most one model call at a time.
    func consider(_ frame: CapturedFrame) {
        let watched = self.watched
        let auto = autoHazards()
        guard !watched.isEmpty || !watchedAllergens.isEmpty || auto else { return }
        var hasher = Hasher()
        hasher.combine(watched)
        hasher.combine(watchedAllergens)
        hasher.combine(atHome)
        let lookKey = hasher.finalize()
        guard !looksInFlight.contains(lookKey) else {
            if waitingFrames[lookKey] != nil {
                Trace.note("safety: waiting frame merged into a newer one")
                let log = eventLog
                Task { await log?("safety.frame", "merged", "a newer frame of the same look took its place") }
            }
            waitingFrames[lookKey] = frame
            return
        }
        let now = Date()
        sentTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard sentTimes.count < tuning.maxPerMinute else { return }
        let home = atHome
        var since = lastSent.map { now.timeIntervalSince($0) } ?? .infinity
        // Something was just read as "on" for the first time: look again at once to confirm it
        // (at least 1 s later, so it is another frame), instead of waiting for the usual slot.
        if let asked = confirmSoon, now.timeIntervalSince(asked) < 20, since >= 1 {
            confirmSoon = nil
            since = .infinity
        }
        // Allergen and "when you see X" rules are checked on enriched memory records (no frame
        // is sent for them); only rules about an object's state need frames of their own.
        let hasAllergenRules = false
        let hasAwayRules = rules.contains { $0.enabled && $0.trigger.type == .event && $0.trigger.state != nil }
        if home {
            recentFrames.removeAll { now.timeIntervalSince($0.at) > Self.stripSeconds }
            // At least 0.7 s apart: the same instant twice shows no movement.
            if recentFrames.last.map({ frame.capturedAt.timeIntervalSince($0.at) >= 0.7 }) ?? true {
                recentFrames.append((frame.jpeg, frame.capturedAt))
                if recentFrames.count > 8 { recentFrames.removeFirst() }
            }
        }
        // Fast path decided without any image work.
        if home, since < tuning.homeHandsEvery { return }
        if !home, !hasAllergenRules, !hasAwayRules { return }
        if !home, since < min(tuning.labelEvery, tuning.awayEvery) { return }
        looksInFlight.insert(lookKey)
        let jpeg = frame.jpeg
        let tuning = self.tuning
        let allergens = watchedAllergens
        let earlier = recentFrames.filter { $0.at < frame.capturedAt.addingTimeInterval(-0.5) }.suffix(Self.stripFrames - 1)
        Task {
            defer {
                self.looksInFlight.remove(lookKey)
                if let next = self.waitingFrames.removeValue(forKey: lookKey) { self.consider(next) }
            }
            // Hands first (cheap); the privacy copy (OCR + head masking) only for frames that are due.
            let hands = await Task.detached(priority: .utility) { SafetyFrame.handsVisible(jpeg) }.value
            let due = home ? (hands ? since >= tuning.homeHandsEvery : since >= tuning.homeEvery)
                           : (hasAwayRules && since >= tuning.awayEvery)
            // Allergen rules: a frame every few seconds, whatever its amount of text (the front
            // of a package can be a big picture and one word).
            let labelCheck = hasAllergenRules && since >= tuning.labelEvery
            guard due || labelCheck else { return }
            guard let copy = await Task.detached(priority: .utility, operation: { SafetyFrame.prepare(jpeg) }).value else { return }
            self.lastSent = Date()
            self.sentTimes.append(Date())
            // Hands at work: the frames just before this one, masked the same way, as a strip.
            var strip: (jpeg: Data, frames: [Data], count: Int, seconds: Int)?
            if hands, !earlier.isEmpty {
                let before = await Task.detached(priority: .utility) {
                    earlier.compactMap { SafetyFrame.prepare($0.jpeg, maxPixel: 768)?.jpeg }
                }.value
                if !before.isEmpty, let picture = QueryEngine.montage(jpegs: before.suffix(Self.sheetFrames - 1) + [copy.jpeg], cell: 768) {
                    strip = (picture, before, before.count + 1, max(1, Int(frame.capturedAt.timeIntervalSince(earlier.first?.at ?? frame.capturedAt).rounded())))
                }
            }
            await self.observe(copy, frame: frame, watched: watched, allergens: allergens, strip: strip)
        }
    }

    private func observe(_ copy: SafetyFrame.Prepared, frame: CapturedFrame, watched: [String], allergens: [String],
                         strip: (jpeg: Data, frames: [Data], count: Int, seconds: Int)? = nil) async {
        let observation: SafetyObservation
        do {
            let ai = ai
            let started = ContinuousClock.now
            let base = SafetyPrompts.observeUser(watched: watched, allergens: allergens, ocr: copy.ocr)
            let stripSize = strip.map { (count: $0.count, seconds: $0.seconds) }
            @Sendable func user(sheet: Bool) -> String {
                base + (stripSize.map { SafetyPrompts.stripNote(frames: sheet ? min($0.count, 4) : $0.count, seconds: $0.seconds) } ?? "")
            }
            // The frames as pictures of their own where the host takes several (sharper than one
            // sheet of small ones); otherwise, or if it refuses, the numbered sheet.
            let separate = await ai.multiImageChat ? (strip?.frames ?? []).map { NemotronClient.ImagePart(jpeg: $0) } : []
            func look(_ earlier: [NemotronClient.ImagePart]) async throws -> SafetyObservation {
                try await Self.afterQuestions(ai) {
                    try await ai.chatJSON(SafetyObservation.self, system: SafetyPrompts.observeSystem, user: user(sheet: earlier.isEmpty),
                                          image: .init(jpeg: earlier.isEmpty ? (strip?.jpeg ?? copy.jpeg) : copy.jpeg), earlierImages: earlier,
                                          jsonSchema: SafetyPrompts.observeSchema, schemaName: "observation", maxTokens: 600,
                                          temperature: 0, background: true)
                }
            }
            do {
                observation = try await look(separate)
            } catch NemotronClient.NemotronError.http(400, _) where !separate.isEmpty {
                observation = try await look([])
            }
            Trace.note("safety look\(strip.map { " (strip of \($0.count), \($0.seconds) s)" } ?? ""): \((ContinuousClock.now - started).milliseconds) ms, frame \(String(format: "%.1f", Date().timeIntervalSince(frame.capturedAt))) s old")
        } catch {
            Log.pipeline.info("safety observe failed: \(String(describing: error), privacy: .public)")
            return
        }
        let file = await store.saveFrame(copy.jpeg)
        // Something was done in these frames: the moments before stay with the evidence frame.
        if let file, let strip, !observation.actions.isEmpty { await store.saveStrip(strip.frames, before: file) }
        await apply(observation, at: frame.capturedAt, frameFile: file, latitude: frame.latitude, longitude: frame.longitude)
    }

    #if DEBUG
    /// The strip look on frames given by a test (already a few seconds of one moment, oldest
    /// first): the same prompt, masking and picture layout as `observe`, nothing stored.
    func debugStripLook(_ frames: [Data], watched: [String], seconds: Int) async -> SafetyObservation? {
        let masked = await Task.detached { frames.compactMap { SafetyFrame.prepare($0, maxPixel: 768, fromPipeline: false) } }.value
        guard masked.count == frames.count, let last = masked.last else { return nil }
        let before = masked.dropLast().map(\.jpeg)
        let ai = ai
        let base = SafetyPrompts.observeUser(watched: watched, allergens: [], ocr: last.ocr)
        let sheet = QueryEngine.montage(jpegs: before.suffix(Self.sheetFrames - 1) + [last.jpeg], cell: 768)
        @Sendable func look(separate: Bool) async throws -> SafetyObservation {
            let count = separate ? masked.count : min(masked.count, 4)
            return try await ai.chatJSON(SafetyObservation.self, system: SafetyPrompts.observeSystem,
                                         user: base + (count > 1 ? SafetyPrompts.stripNote(frames: count, seconds: seconds) : ""),
                                         image: .init(jpeg: separate ? last.jpeg : (sheet ?? last.jpeg)),
                                         earlierImages: separate ? before.map { NemotronClient.ImagePart(jpeg: $0) } : [],
                                         jsonSchema: SafetyPrompts.observeSchema, schemaName: "observation", maxTokens: 600, temperature: 0)
        }
        let several = await ai.multiImageChat && masked.count > 1
        do { return try await look(separate: several) } catch NemotronClient.NemotronError.http(400, _) where several {
            return try? await look(separate: false)
        } catch { return nil }
    }
    #endif

    /// States the frame analysis read on a stored frame (pipeline v2: the second source). They
    /// enter the same state machine as a reading of their own, for watched things only, and
    /// only when no safety look covered that moment — also for frames recorded while the phone
    /// was in the pocket, with the time they were taken.
    func noteEnriched(_ states: [ExtractedRecord.ObjectStateSeen], at: Date) async {
        guard !states.isEmpty else { return }
        if let lastSent, abs(lastSent.timeIntervalSince(at)) < 4 { return }
        let watched = self.watched.map { $0.split(separator: ":").last.map(String.init) ?? $0 }.map { $0.lowercased() }
        for seen in states where seen.state != "unknown" {
            let name = seen.object.lowercased()
            guard let object = watched.first(where: { name.contains($0) || $0.contains(name) }) else { continue }
            Trace.note("safety: \(object)=\(seen.state) from the frame analysis (\(seen.evidence ?? "-"))")
            await observe(object: object, state: seen.state, at: at, frameFile: nil, place: nil, source: .enrichment)
        }
    }

    // MARK: State machine

    /// Applies one frame's reading. Public for the scenario evaluation (no network).
    func apply(_ obs: SafetyObservation, at: Date, frameFile: String?, latitude: Double? = nil, longitude: Double? = nil) async {
        let summary = obs.objects.filter(\.visible).map { "\($0.name)=\($0.state)" } + obs.actions.map { "\($0.object):\($0.action)" }
        lastObservationText = "\(obs.room) · " + (summary.isEmpty ? String(localized: "nothing watched in view") : summary.joined(separator: ", "))
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
        for h in obs.hazards {
            await hazard(h, at: at, frameFile: frameFile)
        }
        if let label = obs.label, label.ingredients_visible || !label.allergens_found.isEmpty {
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
                // A first "on" reading: the confirming look is the next frame, not the next
                // slot 5–30 s later (see `consider`).
                if st.pendingOnCount < tuning.onReadingsNeeded, source == .vision { confirmSoon = Date() }
                if st.pendingOnCount >= tuning.onReadingsNeeded || source != .vision {
                    st = ObjectState(object: object, state: "on", since: at, lastSeen: at, lastStateSeen: at,
                                     evidenceFrame: frameFile ?? st.evidenceFrame, pendingOnCount: 0, source: source, place: st.place,
                                     active: true, hazard: st.hazard)
                    await store.insert(SafetyEvent(at: at, kind: .state, object: object, value: "on", source: source,
                                                   frameFile: frameFile, zone: zone.rawValue))
                }
            }
        } else {
            st.pendingOnCount = 0
            // "Off", "I turned it off", locked, closed …: no longer left on.
            st.active = false
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
            Task { await self.rescheduleNotifications() }
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
        let question = rule.confirmQuestion ?? String(localized: "Did you take your \(name)?")
        await announce(question, rule.language, true, frameFile.map(store.frameURL))
    }

    // MARK: Commands from the answer model

    /// Runs a command; returns a reply that replaces the model's acknowledgement when Muisti has
    /// something more important to say (a warning on leaving).
    func handle(_ command: SafetyCommand, now: Date = Date()) async -> String? {
        switch command {
        case .createRule(var rule):
            rule.enabled = true
            // The same rule again while it waits for a yes ("yes, that's right" read as a
            // request): that is the yes.
            if case .rule(let waiting) = pending, waiting.trigger == rule.trigger, waiting.condition == rule.condition {
                return await handle(.confirm, now: now)
            }
            pending = .rule(rule)
        case .confirm:
            switch pending {
            case .rule(let rule):
                await store.save(rule)
                await reload()
                // Never wait on the system prompt: the conversation must go on while it is shown.
                if rule.trigger.type == .schedule {
                    Task { await self.requestNotificationPermission(); await self.rescheduleNotifications() }
                } else {
                    Task { await self.rescheduleNotifications() }
                }
            case .deleteRule(let rule):
                await store.deleteRule(rule.id)
                await reload()
                Task { await self.rescheduleNotifications() }
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
            // "I turned it off" answers the open warning about that object.
            if let last = alerts.first, last.response == nil, now.timeIntervalSince(last.at) < 30 * 60,
               rules.first(where: { $0.id == last.ruleID })?.watchedObjects.contains(object) == true {
                await store.respond(alert: last.id, .confirmed)
                alerts = await store.alerts()
            }
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
            return lastAlertRule == nil ? nil : String(localized: "Okay, I'll stay quiet about that for 30 minutes.")
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
        // Built in: anything the frame model saw left active, unless a user rule just said it.
        if contextEvent == "left_home", autoHazards() {
            for st in await store.states().map(staled) where st.active && st.state != "unknown" {
                guard !said.contains(where: { $0.lowercased().contains(st.object.lowercased()) }) else { continue }
                let text = String(localized: "I last saw the \(Self.spoken(st.object)) \(st.state) at \(Self.clock(st.lastStateSeen)) and did not see it turned off.")
                if await fireAuto(id: "auto.left.\(st.object)", text: text, frame: st.evidenceFrame, severity: .high,
                                  cooldown: 30, at: at, speak: speak) { said.append(text) }
            }
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
        // Built in: an active hazard at home that nobody has looked at for 20 minutes.
        if autoHazards(), atHome {
            for st in await store.states().map(staled) where st.active && st.hazard
                && now.timeIntervalSince(st.lastSeen) >= 20 * 60 && now.timeIntervalSince(st.lastSeen) < 3 * 3600 {
                let minutes = Int(now.timeIntervalSince(st.lastStateSeen) / 60)
                await fireAuto(id: "auto.idle.\(st.object)",
                               text: String(localized: "The \(Self.spoken(st.object)) may still be \(st.state): I last saw it \(st.state) at \(Self.clock(st.lastStateSeen)), \(minutes) minutes ago."),
                               frame: st.evidenceFrame, severity: .high, cooldown: 30, at: now, speak: true)
            }
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

    // MARK: Enriched memory records → rules

    /// A frame was just understood by the enrichment worker: Nemotron's meaning of it (type,
    /// name, caption, visible things such as "wrapper with strawberry image", keywords, text).
    /// Rules about what is seen (allergens, "when you see X") are matched against that meaning:
    /// when the reranker and the embedding both put the record close to the rule, Muisti warns
    /// at once; a record in between gets a short text-only check; the rest is ignored. No image
    /// goes to the model again.
    ///
    /// Calibrated on 175 real records (14 Nov): the four strawberry-package frames scored rerank
    /// −2.57…−2.71 / cosine 0.23…0.32; the closest wrong ones (a phone screen with a strawberry
    /// chat) −2.97 / 0.21 and −3.26 / 0.23.
    func checkEnriched(recordID: Int64, title: String?, passage: String, vector: [Float]? = nil, frame: Data?,
                       rerankGate: Bool = true) async {
        let now = Date()
        let candidates = rules.filter { rule in
            guard rule.enabled, rule.trigger.type == .event, rule.trigger.state == nil else { return false }
            if rule.condition.allergens?.isEmpty == false { return true }   // cooled down per product, see fire()
            if let last = alerts.first(where: { $0.ruleID == rule.id }),
               now.timeIntervalSince(last.at) < Double(rule.cooldown_min) * 60 { return false }
            return true
        }
        guard !candidates.isEmpty else { return }
        // The rules are checked side by side (each is one or two network calls); the warnings
        // are then given one after another, in the rules' order.
        var matched: [(index: Int, label: SafetyObservation.Label)] = []
        await withTaskGroup(of: (Int, SafetyObservation.Label?).self) { group in
            for (index, rule) in candidates.enumerated() {
                group.addTask {
                    (index, await self.match(rule, recordID: recordID, title: title, passage: passage, vector: vector, rerankGate: rerankGate))
                }
            }
            for await (index, label) in group {
                if let label { matched.append((index, label)) }
            }
        }
        guard !matched.isEmpty else { return }
        var file: String?
        if let frame { file = await store.saveFrame(frame) }
        for hit in matched.sorted(by: { $0.index < $1.index }) {
            await fire(candidates[hit.index], at: Date(), label: hit.label, speak: true, frameFile: file)
        }
    }

    /// Whether one rule applies to a record, as the label to warn with (nil: it does not).
    private func match(_ rule: SafetyRule, recordID: Int64, title: String?, passage: String, vector: [Float]?,
                       rerankGate: Bool) async -> SafetyObservation.Label? {
        let query = Self.ruleQuery(rule)
        var direct = false
        if rerankGate {
            var score: Double?
            if await ai.rerankEnabled { score = try? await ai.rerank(query: query, passages: [passage], paced: true).first }
            var cosine: Double?
            if let vector, let q = await queryVector(query) { cosine = Self.cosine(vector, q) }
            Log.pipeline.info("safety rule check #\(recordID) [\(rule.id.prefix(8), privacy: .public)] rerank \(score.map { String(format: "%.2f", $0) } ?? "-", privacy: .public) cos \(cosine.map { String(format: "%.3f", $0) } ?? "-", privacy: .public)")
            let t = tuning
            switch (score, cosine) {
            case let (s?, c):
                direct = s >= t.ruleDirectLogit && (c ?? 1) >= t.ruleDirectCosine
                if !direct, s < t.ruleGateLogit, (c ?? 0) < t.ruleGateCosine { return nil }
            case let (nil, c?):
                direct = c >= t.ruleDirectCosineAlone
                if !direct, c < t.ruleGateCosine { return nil }
            case (nil, nil):
                break   // nothing to measure with: the text check decides
            }
        }
        let label: SafetyObservation.Label
        if direct {
            label = SafetyObservation.Label(product: title, ingredients_visible: false, source: "front",
                                            allergens_found: rule.condition.allergens ?? [], evidence: "close to the rule in meaning")
        } else {
            let match: SafetyPrompts.Match
            do {
                let ai = ai
                match = try await Self.afterQuestions(ai) {
                    try await ai.chatJSON(SafetyPrompts.Match.self, system: SafetyPrompts.matchSystem,
                                          user: "Rule: \(query)\n\nRecord:\n\(passage.prefix(2500))",
                                          jsonSchema: SafetyPrompts.matchSchema, schemaName: "match", maxTokens: 200,
                                          temperature: 0, background: true)
                }
            } catch {
                return nil
            }
            Log.pipeline.info("safety rule check #\(recordID): matches \(match.matches) \(match.found, privacy: .public) · \(match.evidence, privacy: .public)")
            guard match.matches else { return nil }
            let found = match.found.map { $0.lowercased() }
            label = SafetyObservation.Label(product: match.product ?? title, ingredients_visible: match.from_ingredients,
                                            source: match.from_ingredients ? "ingredients" : "front",
                                            allergens_found: found.isEmpty ? (rule.condition.allergens ?? []) : found,
                                            evidence: match.evidence)
        }
        return label
    }

    /// A safety call, in the safety lane.
    private static func afterQuestions<T: Sendable>(_ ai: NemotronClient, _ call: @Sendable () async throws -> T) async throws -> T {
        // Safety looks have their own lane: a question neither cancels nor delays them.
        try await LaneKind.$current.withValue(.safety) { try await call() }
    }

    @ObservationIgnored private var queryVectors: [String: [Float]] = [:]

    /// The rule's query embedding (cached per query text).
    private func queryVector(_ query: String) async -> [Float]? {
        if let cached = queryVectors[query] { return cached }
        guard await ai.embeddingsEnabled, let v = try? await ai.embed(query, as: .query) else { return nil }
        queryVectors[query] = v
        return v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i])
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : nil
    }

    /// Fast path: a frame was just stored and OCR read text on it (e.g. "MANSIKKA" on a
    /// package). Checked within seconds, before the image enrichment; the same text seen again
    /// within a minute is not checked twice.
    func checkText(recordID: Int64, text: String, frame: Data) async {
        guard rules.contains(where: { $0.enabled && $0.trigger.type == .event && $0.trigger.state == nil }) else { return }
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })
        guard !words.isEmpty else { return }
        let now = Date()
        recentTexts.removeAll { now.timeIntervalSince($0.at) > 60 }
        // The same package read a little differently in the next frame is not new text.
        if recentTexts.contains(where: { Double($0.words.intersection(words).count) / Double($0.words.union(words).count) >= 0.5 }) { return }
        recentTexts.append((words, now))
        // No rerank gate here: raw OCR in another language ("MANSIKKA") scores like any other
        // text (-3.3), so the short text check decides alone.
        await checkEnriched(recordID: recordID, title: nil, passage: "Text read on the frame (OCR):\n\(text)",
                            frame: frame, rerankGate: false)
    }

    /// The rule as a retrieval query.
    static func ruleQuery(_ rule: SafetyRule) -> String {
        if let allergens = rule.condition.allergens, !allergens.isEmpty {
            return "A food or drink product that contains \(allergens.joined(separator: ", ")) (as an ingredient, in its flavour or name, or shown on the package)"
        }
        let object = rule.trigger.object.map(spoken) ?? rule.watch.first.map(spoken) ?? rule.summary
        return object
    }

    // MARK: Built-in hazards

    /// One reading of a hazard the model flagged by itself. "Active" needs two readings in a
    /// row (one wrong reading must not alarm); inactive counts at once. Danger happening now
    /// (smoke, boiling over) is said as soon as it is confirmed.
    private func hazard(_ h: SafetyObservation.Hazard, at: Date, frameFile: String?) async {
        guard autoHazards() || watched.contains(h.object) else { return }
        var st = await currentState(h.object) ?? ObjectState(object: h.object, state: "unknown", since: at, lastSeen: at,
                                                              lastStateSeen: at, evidenceFrame: frameFile, source: .vision,
                                                              place: h.location_hint)
        st.lastSeen = at
        st.hazard = true
        if let place = h.location_hint { st.place = place }
        if h.active {
            if st.active {
                st.state = h.state
                st.lastStateSeen = at
                st.evidenceFrame = frameFile ?? st.evidenceFrame
            } else {
                st.pendingOnCount += 1
                if st.pendingOnCount >= tuning.onReadingsNeeded {
                    st.state = h.state
                    st.active = true
                    st.since = at
                    st.lastStateSeen = at
                    st.pendingOnCount = 0
                    st.evidenceFrame = frameFile ?? st.evidenceFrame
                    await store.insert(SafetyEvent(at: at, kind: .state, object: h.object, value: h.state, source: .vision,
                                                   frameFile: frameFile, zone: zone.rawValue, detail: "hazard: \(h.evidence)"))
                }
            }
        } else {
            st.pendingOnCount = 0
            if st.active || st.state != h.state {
                await store.insert(SafetyEvent(at: at, kind: .state, object: h.object, value: h.state, source: .vision,
                                               frameFile: frameFile, zone: zone.rawValue, detail: "hazard: \(h.evidence)"))
            }
            st.active = false
            st.state = h.state
            st.since = at
            st.lastStateSeen = at
            st.evidenceFrame = frameFile ?? st.evidenceFrame
        }
        await store.save(st)
        if h.immediate, st.active {
            await fireAuto(id: "auto.now.\(h.object)",
                           text: String(localized: "Careful: I see the \(Self.spoken(h.object)) \(h.state)") + (st.place.map { ", \($0)" } ?? "") + ".",
                           frame: frameFile, severity: .high, cooldown: 10, at: at, speak: true)
        }
    }

    /// A built-in warning (no user rule): same cooldown, snooze and logging as rule alerts.
    @discardableResult
    private func fireAuto(id: String, text: String, frame: String?, severity: SafetyRule.Severity, cooldown: Int,
                          at: Date, speak: Bool) async -> Bool {
        if let until = snoozedUntil[id], at < until { return false }
        if let last = alerts.first(where: { $0.ruleID == id }), at.timeIntervalSince(last.at) < Double(cooldown) * 60 { return false }
        let alert = SafetyAlert(at: at, ruleID: id, message: text, evidenceFrame: frame, severity: severity)
        await store.insert(alert)
        alerts = await store.alerts()
        lastAlertRule = id
        Log.pipeline.info("safety auto alert [\(id, privacy: .public)]: \(text, privacy: .public)")
        Trace.note("safety auto alert [\(id)] \(String(format: "%.1f", Date().timeIntervalSince(at))) s after the frame: \(text.prefix(80))")
        if speak { await announce(text, nil, false, frame.map(store.frameURL)) }
        await notifyIfBackground(text)
        return true
    }

    /// "front_door" → "front door".
    static func spoken(_ object: String) -> String {
        (object.split(separator: ":").last.map(String.init) ?? object).replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Rule evaluation

    /// Condition check + alert. Returns the spoken text if the rule fired.
    @discardableResult
    private func fire(_ rule: SafetyRule, at: Date, label: SafetyObservation.Label?, speak: Bool,
                      frameFile: String? = nil, ignoreCooldown: Bool = false) async -> String? {
        if let until = snoozedUntil[rule.id], at < until { return nil }
        // Allergens: every product is its own warning (a new product warns at once; the same
        // one again after a few minutes), not one warning per rule per half hour.
        let productKey = rule.condition.allergens?.isEmpty == false
            ? label.map { rule.id + "|" + ($0.product ?? "").lowercased().filter(\.isLetter) } : nil
        if !ignoreCooldown {
            if let productKey {
                if let last = productAlerts[productKey], at.timeIntervalSince(last) < tuning.productCooldownMinutes * 60 { return nil }
                // The same package read slightly differently in the next frames: not again at once.
                if let last = alerts.first(where: { $0.ruleID == rule.id }), at.timeIntervalSince(last.at) < 45 { return nil }
            } else if let last = alerts.first(where: { $0.ruleID == rule.id }),
                      at.timeIntervalSince(last.at) < Double(rule.cooldown_min) * 60 { return nil }
        }
        guard let filled = await evaluate(rule, at: at, label: label) else { return nil }
        if let productKey { productAlerts[productKey] = at }
        var text = Self.fill(rule.message, with: filled.values)
        // A placeholder with nothing to fill ("… at {place}.") would leave a broken sentence.
        if Self.hasEmptyPlaceholder(rule.message, values: filled.values) {
            text = Self.defaultMessage(rule, values: filled.values) ?? text
        }
        if let label, label.source == "front", !label.ingredients_visible {
            text += " " + String(localized: "I only saw the front of the package; check the ingredients.")
        }
        let alert = SafetyAlert(at: at, ruleID: rule.id, message: text, evidenceFrame: filled.frame ?? frameFile, severity: rule.severity)
        await store.insert(alert)
        await store.setLastFired(rule.id, at)
        alerts = await store.alerts()
        lastAlertRule = rule.id
        Log.pipeline.info("safety alert [\(rule.id, privacy: .public)]: \(text, privacy: .public)")
        Trace.note("safety alert [\(rule.id.prefix(8))] \(String(format: "%.1f", Date().timeIntervalSince(at))) s after the frame: \(text.prefix(80))")
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

    static func hasEmptyPlaceholder(_ template: String, values: [String: String]) -> Bool {
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let key = String(rest[rest.index(after: open)..<close])
            if (values[key] ?? "").isEmpty { return true }
            rest = rest[rest.index(after: close)...]
        }
        return false
    }

    static func defaultMessage(_ rule: SafetyRule, values: [String: String]) -> String? {
        if let allergens = values["allergens"], !allergens.isEmpty {
            let product = values["product"].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "This product")
            return String(localized: "Careful: \(product) seems to contain \(allergens).")
        }
        return nil
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
        var seen = Set<String>()
        return events.filter { ids.contains($0.id) }.sorted { $0.at < $1.at }.compactMap(\.frameFile)
            .filter { seen.insert($0).inserted }.flatMap(store.sequenceURLs)
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

