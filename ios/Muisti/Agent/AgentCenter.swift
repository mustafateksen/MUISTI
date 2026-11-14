import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// The agent side of Muisti: keeps what the user asked to be reminded of, where they are going
/// and what they told it, watches what the glasses see, where the phone is and what time it is,
/// and brings something up by itself when — and only when — it is the moment for it.
///
/// How it stays cheap and quiet:
/// - triggers computed on the phone come first (a time is due, a named place is near, the user
///   walks away from their destination, got out of a car, a calendar event is close);
/// - what a frame shows is matched against open intents by embedding and reranker (`matching`),
///   and the enrichment the frame gets anyway flags the few frames worth a second look;
/// - only then is the model asked whether to speak (`Notice.judge`), and its sentence is
///   checked against what it was shown;
/// - `InterventionPolicy` has the last word on how loudly and when.
@Observable
@MainActor
final class AgentCenter {
    let store: AgentStore
    let settings: AgentSettings
    let policy: InterventionPolicy
    let calendar = CalendarReader()
    /// Wake-ups while Muisti is in the background (needs "Always" location access).
    let background = BackgroundRuntime()

    private(set) var intents: [Intent] = []
    private(set) var places: [NamedPlace] = []
    private(set) var facts: [UserFact] = []
    private(set) var pending: AgentPending?
    /// The last judgement, for the developer view.
    private(set) var lastJudgement = "—"
    private(set) var judgements = 0
    /// A frame is being weighed, or one is waiting for its turn (the remote driver waits for this).
    var isWeighing: Bool { judging || !waitingNotices.isEmpty }

    @ObservationIgnored private let ai: NemotronClient
    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let motion: MotionProvider
    @ObservationIgnored private let notifications = AgentNotifications()
    /// The language Muisti speaks to the user in (the voice setting), for sentences it writes itself.
    @ObservationIgnored var language: () -> String? = { nil }
    /// Capture is running (frames, GPS): the periodic review only runs then.
    @ObservationIgnored var isCapturing: () -> Bool = { false }

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var cueVectors: [String: [Float]] = [:]
    @ObservationIgnored private var judging = false
    /// Records waiting for their turn with the judge, oldest first. Every one gets looked at
    /// (before, only the newest was kept and the ones in between were lost); one that has
    /// waited long is still judged and reaches the user as a late note, not as speech.
    @ObservationIgnored private var waitingNotices: [EnrichmentWorker.Noticed] = []
    static let maxWaitingNotices = 40
    @ObservationIgnored private var navigator = Navigator()
    /// The walking route to the destination, when Apple Maps found one.
    private(set) var route: RouteGuide?
    @ObservationIgnored private var routeBusy = false
    @ObservationIgnored private var lastReroute: Date?
    @ObservationIgnored private var placeLookups: [String: (at: CLLocation, when: Date)] = [:]
    @ObservationIgnored private var wasHome: Bool?
    @ObservationIgnored private var drivingSince: Date?
    @ObservationIgnored private var lastAutomotive: Date?
    @ObservationIgnored private var announcedEvents: Set<String> = []
    @ObservationIgnored private var lastReview: (at: Date, state: Int)?
    @ObservationIgnored private var ticking = false
    /// The evaluation drives `tick` itself, with its own clock.
    @ObservationIgnored var timerPaused = false

    /// What Muisti keeps an eye out for without being asked: the user's own things and what can
    /// be left on. Matched like the cue of an intent (embedding, then reranker), so whether a
    /// frame gets a second look does not hang on the enrichment remembering to flag it.
    static let standing: [(id: String, sight: String)] = [
        ("medicine", "Medicine seen up close: a medicine box, a blister pack of pills or capsules, a pill bottle, tablets in a hand."),
        ("belongings", "Personal belongings put down or left behind: keys, a wallet, a phone, glasses, a bag or an umbrella lying on a table, seat or counter."),
        ("left_on", "Something at home left on or open: a lit stove or hob with a flame or glowing ring, an iron, a running tap, an open front door or window."),
        ("hazard", "A danger on the ground right where a person is walking: a wet floor warning sign, a red pedestrian light at a crossing, a marked bicycle lane underfoot, roadworks, an open hole or a barrier across the path."),
    ]
    /// A danger underfoot is only worth words while the user is still in front of it.
    static let hazardFresh: TimeInterval = 20

    /// Muisti Turva's rules and log as text, for the summary of the day.
    @ObservationIgnored var safetyContext: (@Sendable () async -> String)?

    /// Muisti Turva's log since a date, for working out what the user usually does (`Habits`).
    @ObservationIgnored var safetyEvents: (@Sendable (Date) async -> [SafetyEvent])?

    func habits(now: Date = Date()) async -> [Habits.Habit] {
        guard settings.noticing, let safetyEvents else { return [] }
        return Habits.find(in: await safetyEvents(now.addingTimeInterval(-15 * 86_400)), now: now)
    }

    static let snooze: TimeInterval = 30 * 60
    static let nearPlace: Double = 90
    /// Muisti's own look at how the day is going, while capturing and when something changed
    /// (pipeline v2: every 2 minutes; it was 10 when the server was shared and slow).
    static let reviewEvery: TimeInterval = 2 * 60

    init(ai: NemotronClient, memory: MemoryStore, location: LocationProvider, motion: MotionProvider) {
        self.ai = ai
        self.memory = memory
        self.location = location
        self.motion = motion
        store = AgentStore()
        settings = AgentSettings()
        policy = InterventionPolicy(store: store, settings: settings)
        policy.activity = { [weak motion] in motion?.activity ?? .unknown }
        policy.notify = { text, intentID, interventionID in
            await AgentNotifications.post(text, intentID: intentID, interventionID: interventionID)
        }
        notifications.install()
        notifications.onAction = { [weak self] action, intent, intervention in
            await self?.notificationAction(action, intentID: intent, interventionID: intervention)
        }
        background.registerRefresh()
        background.onWake = { [weak self] location in
            guard let self else { return }
            if let location { self.location.inject(location) }
            await self.reload()
            await self.tick()
        }
        background.start()
        background.scheduleRefresh()
        Task { await reload() }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if self?.timerPaused == false { await self?.tick() }
            }
        }
    }

    isolated deinit { timer?.cancel() }

    func reload() async {
        intents = await store.intents()
        places = await store.places()
        facts = await store.facts()
        await policy.reload()
        watchPlaces()
    }

    /// The places the system should wake Muisti for: where an intent waits, and the named places.
    private func watchPlaces() {
        guard background.isAlways else { return }
        var watched: [(id: String, coordinate: CLLocationCoordinate2D, radius: Double)] = []
        for intent in intents where intent.status == .open && intent.kind != .parking {
            if let coordinate = intent.coordinate { watched.append((intent.id, coordinate, 120)) }
        }
        for place in places where place.id != "car" { watched.append(("place." + place.id, place.location.coordinate, place.radius)) }
        if let home, !places.contains(where: { $0.id == "home" }) { watched.append(("place.home", home.location.coordinate, home.radius)) }
        background.watch(watched, near: location.latest?.clLocation)
    }

    func purge(retentionDays: Int) async {
        await store.purge(olderThanDays: retentionDays)
        await reload()
    }

    func forget(since: Date) async {
        for intent in intents where intent.createdAt >= since { AgentNotifications.cancel(intentID: intent.id) }
        await store.delete(since: since)
        await reload()
    }

    func deleteAll() async {
        intents.forEach { AgentNotifications.cancel(intentID: $0.id) }
        await store.deleteAll()
        pending = nil
        await reload()
    }

    // MARK: What the model is told

    private var destination: Intent? { intents.last { $0.kind == .destination && $0.status == .open } }

    /// Home: the place named "home", or the one Muisti Turva keeps.
    private var home: NamedPlace? {
        if let named = places.first(where: { $0.id == "home" }) { return named }
        guard let saved = UserDefaults.standard.array(forKey: "safety.home") as? [Double], saved.count == 2 else { return nil }
        return NamedPlace(name: "home", latitude: saved[0], longitude: saved[1])
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 950 ? "\(Int((meters / 10).rounded()) * 10) m" : String(format: "%.1f km", meters / 1000)
    }

    private func whereText(_ coordinate: CLLocationCoordinate2D, from fix: LocationFix?) -> String? {
        guard let fix else { return nil }
        let meters = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: fix.clLocation)
        let bearing = Places.bearing(from: fix.clLocation.coordinate, to: coordinate)
        return "\(distanceText(meters)) away, \(Places.relative(bearing: bearing, course: fix.validCourse))"
    }

    private static func cueText(_ cue: Cue) -> String {
        var parts: [String] = []
        if let at = cue.at { parts.append("at \(at)") }
        if let daily = cue.daily { parts.append("daily \(daily)") }
        if let place = cue.place { parts.append("place “\(place)”") }
        if let sight = cue.sight { parts.append("on seeing: \(sight)") }
        if let on = cue.on { parts.append(on) }
        return parts.isEmpty ? "" : " [when: " + parts.joined(separator: "; ") + "]"
    }

    /// The area a place name stands for (the user's own places first, then the map), for
    /// searching the memory by place.
    func area(named name: String, here: LocationFix?) async -> MemoryArea? {
        await Places.area(name, known: await store.places(), here: here, maps: settings.mapSearch)
    }

    /// The agent's notes as the models read them: in the turn decision, in the answer (so "where
    /// is my car", "what did I want to buy" are answered from it) and in the judge call.
    func promptContext(now: Date = Date()) -> String {
        let fix = location.freshFix(maxAge: 120)
        var lines: [String] = ["Muisti's own notes for the user (reminders, places, what they told Muisti):"]
        let open = intents.filter { $0.status == .open && $0.kind != .destination }
        lines.append("Open intents:" + (open.isEmpty ? " (none)" : ""))
        for intent in open {
            var line = "- intent \(intent.id) (\(intent.kind.rawValue), \(intent.source == .user ? "asked by the user" : "noted by Muisti") \(QueryEngine.promptTime(intent.createdAt))): \(intent.text)\(Self.cueText(intent.cue))"
            if let coordinate = intent.coordinate, let whereabouts = whereText(coordinate, from: fix) {
                line += " [\(intent.placeName.map { "\($0), " } ?? "")\(whereabouts)]"
            }
            if let until = intent.snoozeUntil, now < until { line += " [not before \(QueryEngine.promptTime(until))]" }
            if let fired = intent.firedAt { line += " [last brought up \(QueryEngine.promptTime(fired))]" }
            lines.append(line)
        }
        if let destination {
            var line = "Destination: \(destination.placeName ?? destination.text) (said \(QueryEngine.promptTime(destination.createdAt)), intent \(destination.id))"
            if let coordinate = destination.coordinate {
                line += whereText(coordinate, from: fix).map { " — \($0)" } ?? " — position known, no fresh GPS fix"
            } else {
                line += " — not found on the map; watching for its sign"
            }
            lines.append(line)
            if let route, let fix {
                var guide = "Walking route (Apple Maps): \(distanceText(route.remainingMeters)) left"
                if let next = route.upcoming(from: fix.clLocation) { guide += "; next turn in \(distanceText(next.meters)): \(next.instruction)" }
                lines.append(guide)
            }
        } else {
            lines.append("Destination: (none)")
        }
        var named = places
        if let home, !named.contains(where: { $0.id == "home" }) { named.insert(home, at: 0) }
        lines.append("Named places:" + (named.isEmpty ? " (none)" : ""))
        for place in named {
            var line = "- \(place.name)"
            if place.id == "car" { line += " (parked \(QueryEngine.promptTime(place.setAt)))" }
            if let detail = place.detail { line += ": \(detail)" }
            if let whereabouts = whereText(place.location.coordinate, from: fix) { line += " — \(whereabouts)" }
            lines.append(line)
        }
        if !facts.isEmpty {
            lines.append("What the user told Muisti about themselves:")
            lines += facts.suffix(20).map { "- \($0.text) (said \(QueryEngine.promptTime($0.at)))" }
        }
        if settings.calendar, calendar.canRead {
            lines.append("User's calendar, next 24 hours:" + (calendar.upcoming.isEmpty ? " (nothing)" : ""))
            lines += calendar.upcoming.map { e in
                "- \(e.allDay ? "all day \(Cue.stamp(e.start).prefix(10))" : "\(Cue.stamp(e.start))–\(Cue.stamp(e.end).suffix(5))") \(e.title)" + (e.location.map { " @ \($0)" } ?? "")
            }
        }
        if motion.isRunning, motion.activity != .unknown { lines.append("Movement now: \(motion.activity.rawValue)") }
        if let last = policy.recent.first(where: { $0.level > .silent }) {
            lines.append("Last thing Muisti brought up by itself: \(QueryEngine.promptTime(last.at)) [\(last.topic)\(last.intentID.map { ", intent \($0)" } ?? "")] “\(last.text)”" + (last.outcome.map { " (the user: \($0.rawValue))" } ?? ""))
        }
        if !policy.mutes.isEmpty { lines.append("Muted by the user: " + policy.mutes.map(\.topic).joined(separator: ", ")) }
        lines.append("Notes about people (text on badges and cards): \(settings.people ? "allowed" : "not allowed")")
        if let language = language() { lines.append("Muisti speaks to the user in: \(language)") }
        if let pending { lines.append("Pending yes/no: \(pending.prompt)") }
        return lines.joined(separator: "\n")
    }

    private func situation(now: Date) -> String {
        "Current local time: \(QueryEngine.promptTime(now))\nUser position now: \(location.positionText() ?? "unknown")\n" + promptContext(now: now)
    }

    /// The conversation with the user, as the question side reads it: the judge sees it too
    /// ("I'm in a meeting", "I already took it", "I'm waiting for Ali" change what is worth saying).
    @ObservationIgnored var dialogLines: (@Sendable (Date) async -> [String])?
    /// The look-up tools of the agent loop.
    @ObservationIgnored var toolbox: ReadToolbox?
    /// Where a decision to stay silent is written into the conversation stream.
    @ObservationIgnored var dialog: DialogStore?

    private func situationWithTalk(now: Date) async -> String {
        let talk = await dialogLines?(now) ?? []
        return situation(now: now) + (talk.isEmpty ? "" : "\n\nConversation with the user so far (oldest first; what they told you counts — plans, what they already did, a wish not to be disturbed):\n" + talk.joined(separator: "\n"))
    }

    // MARK: Commands (the user's turn)

    /// Runs what the user asked for. A returned text replaces the model's reply.
    func handle(_ command: AgentCommand, now: Date = Date()) async -> String? {
        switch command {
        case .remember(let text, let say, let kind, let cue):
            var intent = Intent(kind: kind, text: text)
            intent.say = say
            intent.cue = cue
            intent.language = language()
            intent.createdAt = now
            await resolvePlace(&intent)
            await save(intent)
            // Asked on the side: the system's permission sheet must not hold the spoken reply back.
            if !cue.isEmpty { Task { _ = await AgentNotifications.requestPermission() } }
            Trace.note("agent intent \(intent.id) [\(kind.rawValue)] \(text.prefix(60))\(Self.cueText(cue))")
        case .setDestination(let name):
            for old in intents where old.kind == .destination { await close(old, as: .dropped) }
            var intent = Intent(kind: .destination, text: name)
            intent.placeName = name
            intent.cue = Cue(place: name)
            intent.language = language()
            await resolvePlace(&intent)
            await save(intent)
            navigator.reset(target: intent.id)
            route = nil
            Task { await self.planRoute(announce: true) }
            Trace.note("agent destination “\(name)” → \(intent.coordinate.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "not found")")
        case .cancelDestination:
            for old in intents where old.kind == .destination { await close(old, as: .dropped) }
            navigator.reset(target: nil)
            route = nil
        case .complete(let id):
            guard let intent = intents.first(where: { $0.id == id }) else { return nil }
            await close(intent, as: .done)
            if policy.lastDelivered?.intentID == id { await policy.setOutcome(.accepted) }
        case .drop(let id):
            guard let intent = intents.first(where: { $0.id == id }) else { return nil }
            await close(intent, as: .dropped)
            if policy.lastDelivered?.intentID == id { await policy.setOutcome(.dismissed) }
        case .rememberFact(let text):
            await store.add(fact: text, at: now)
            facts = await store.facts()
        case .namePlace(let name):
            guard let fix = location.freshFix(maxAge: 300) else { return String(localized: "I don't have your location yet, so I can't save this place.") }
            await savePlace(name: name, at: fix, detail: nil)
        case .mute(let topic, let intentID, let minutes):
            let last = policy.lastDelivered
            let target = intentID.map { "intent:\($0)" } ?? topic.map(Notice.topic)
                ?? (last?.intentID).map { "intent:\($0)" } ?? last?.topic
            guard let target else { return nil }
            await policy.mute(topic: target, minutes: minutes)
            if last != nil { await policy.setOutcome(.muted) }
            if target.hasPrefix("intent:"), let intent = intents.first(where: { "intent:\($0.id)" == target }), minutes == nil {
                await close(intent, as: .dropped)
            }
            Trace.note("agent muted “\(target)” \(minutes.map { "for \($0) min" } ?? "for good")")
        case .summarizeDay:
            return await digest(now: now) ?? String(localized: "I couldn't put your day together just now.")
        case .addToCalendar(let title, let start, let minutes, let location):
            guard let date = Cue(at: start).nextDue(after: now) else { return nil }
            let added = await calendar.add(title: title, start: date, minutes: minutes ?? 60, location: location, notes: nil)
            return added ? nil : String(localized: "I couldn't add it: Muisti has no access to your calendar.")
        }
        return nil
    }

    /// A yes or no to the agent's own question. nil: nothing of the agent's was pending.
    func resolvePending(_ yes: Bool) async -> String? {
        guard let waiting = pending else { return nil }
        pending = nil
        switch waiting {
        case .calendar(let title, let start, let minutes, let place):
            guard yes else {
                await policy.setOutcome(.dismissed)
                return String(localized: "Okay, I won't add it.")
            }
            let added = await calendar.add(title: title, start: start, minutes: minutes, location: place, notes: nil)
            await policy.setOutcome(added ? .accepted : .dismissed)
            return added ? String(localized: "Added to your calendar.") : String(localized: "I couldn't add it: Muisti has no access to your calendar.")
        }
    }

    /// "Not now" after something the agent said. nil: the last thing said was not the agent's.
    func snoozeLast(now: Date = Date()) async -> String? {
        guard let last = policy.lastDelivered, last.source == "agent", now.timeIntervalSince(last.at) < 10 * 60 else { return nil }
        if let id = last.intentID, var intent = intents.first(where: { $0.id == id }) {
            intent.snoozeUntil = now.addingTimeInterval(Self.snooze)
            await save(intent)
        } else {
            await policy.mute(topic: last.topic, minutes: Int(Self.snooze / 60))
        }
        await policy.setOutcome(.snoozed)
        return String(localized: "Okay, I'll stay quiet about that for 30 minutes.")
    }

    func notificationAction(_ action: AgentNotifications.Action, intentID: String?, interventionID: Int64?) async {
        await reload()
        let intent = intentID.flatMap { id in intents.first { $0.id == id } }
        switch action {
        case .done:
            if let intent { await close(intent, as: .done) }
            await policy.setOutcome(.accepted, id: interventionID)
        case .later:
            if var intent {
                intent.snoozeUntil = Date().addingTimeInterval(Self.snooze)
                intent.firedAt = Date()
                await save(intent)
            }
            await policy.setOutcome(.snoozed, id: interventionID)
        case .never:
            if let intent {
                await policy.mute(topic: "intent:\(intent.id)", minutes: nil)
                await close(intent, as: .dropped)
            } else if let entry = policy.recent.first(where: { $0.id == interventionID }) {
                await policy.mute(topic: entry.topic, minutes: nil)
            }
            await policy.setOutcome(.muted, id: interventionID)
        case .opened:
            break
        }
    }

    // MARK: For the notes screen

    func markDone(_ intent: Intent) async { await close(intent, as: .done) }
    func remove(_ intent: Intent) async { await close(intent, as: .dropped) }

    func remove(_ place: NamedPlace) async {
        await store.deletePlace(place.id)
        places = await store.places()
    }

    func remove(_ fact: UserFact) async {
        await store.deleteFact(fact.id)
        facts = await store.facts()
    }

    // MARK: Intents and places

    private func save(_ intent: Intent) async {
        await store.save(intent)
        intents = await store.intents()
        await AgentNotifications.schedule(intent)
    }

    private func close(_ intent: Intent, as status: Intent.Status) async {
        var closed = intent
        closed.status = status
        await store.save(closed)
        AgentNotifications.cancel(intentID: intent.id)
        intents = await store.intents()
    }

    private func savePlace(name: String, at fix: LocationFix, detail: String?) async {
        let around = [location.street, location.areaText(for: fix)].compactMap { $0 }.joined(separator: ", ")
        let text = [detail, around.isEmpty ? nil : around].compactMap { $0 }.joined(separator: "; ")
        var place = NamedPlace(name: name.lowercased(), latitude: fix.latitude, longitude: fix.longitude)
        place.detail = text.isEmpty ? nil : text
        place.setAt = fix.timestamp
        await store.save(place)
        places = await store.places()
        Trace.note("agent place “\(place.name)” saved\(place.detail.map { ": \($0)" } ?? "")")
    }

    /// Gives a place cue coordinates when it names one of the user's places, or (destinations,
    /// with map look-ups allowed) the nearest match on the map.
    private func resolvePlace(_ intent: inout Intent) async {
        guard let words = intent.cue.place else { return }
        let all = places + (home.map { [$0] } ?? [])
        if let named = all.first(where: { $0.name.caseInsensitiveCompare(words) == .orderedSame }) {
            intent.latitude = named.latitude
            intent.longitude = named.longitude
            intent.placeName = named.name
            return
        }
        guard intent.kind == .destination, settings.mapSearch, let fix = location.freshFix(maxAge: 300) else { return }
        if let found = await Places.search(words, near: fix.clLocation.coordinate, radius: 5000).first {
            intent.latitude = found.latitude
            intent.longitude = found.longitude
            intent.placeName = found.name
        }
    }

    // MARK: What the glasses saw

    /// A frame was just enriched: is it what an open intent waits for, or did its analysis flag
    /// something? Only then is the model asked.
    func noticed(_ n: EnrichmentWorker.Noticed) async {
        guard settings.enabled else { return }
        guard !judging else {
            await dialog?.logEvent(kind: "record.noticed", state: "queued", detail: n.title, recordID: n.recordID)
            waitingNotices.append(n)
            if waitingNotices.count > Self.maxWaitingNotices {
                let dropped = waitingNotices.removeFirst()
                await dialog?.logEvent(kind: "record.noticed", state: "expired", detail: "more than \(Self.maxWaitingNotices) waiting", recordID: dropped.recordID)
                await logSilent(topic: "notice", text: dropped.title ?? "", reason: "expired: more than \(Self.maxWaitingNotices) records were waiting for a judgement",
                                recordID: dropped.recordID)
            }
            return
        }
        judging = true
        defer {
            judging = false
            if !waitingNotices.isEmpty {
                let next = waitingNotices.removeFirst()
                Task { await self.noticed(next) }
            }
        }
        let candidates = await matching(n)
        await dialog?.logEvent(kind: "record.noticed", state: "handled", detail: n.title, recordID: n.recordID)
        var flag = n.attention.flatMap { $0 == "none" ? nil : $0 }
        // The enrichment did not flag it, but it looks like one of the things Muisti watches for anyway.
        if flag == nil, settings.noticing, let own = await standingMatch(n) { flag = "personal (\(own))" }
        if flag == "person_badge", !settings.people { flag = nil }
        if !settings.noticing { flag = nil }
        let now = Date()
        if flag == "personal (hazard)", now.timeIntervalSince(n.seenAt) > Self.hazardFresh { flag = nil }
        guard !candidates.isEmpty || flag != nil else { return }
        var record = "id \(n.recordID), seen \(QueryEngine.promptTime(n.seenAt))\n\(n.passage.prefix(1800))"
        if let flag { record += "\nFlag from the frame's analysis: \(flag)\(n.reason.map { " — \($0)" } ?? "")" }
        let related = await related(to: n)
        let ago = Int(max(0, now.timeIntervalSince(n.seenAt)))
        let happened: String
        if !candidates.isEmpty {
            happened = "The glasses saw the frame below \(ago) seconds ago, and it resembles what an open intent is waiting for."
        } else if flag == "personal (hazard)" {
            happened = "The glasses saw the frame below \(ago) seconds ago. It may show a danger on the ground where the user is walking right now. If it is real, close and ahead of them (not a picture, not across the street, not something they are plainly already dealing with), warn them in one short urgent sentence; otherwise stay silent."
        } else if flag?.hasPrefix("personal") == true {
            happened = "The glasses saw the frame below \(ago) seconds ago. It looks like something of the user's own, or something left on or open: the kind of thing you look out for without being asked. Check the notes and the safety log for whether it is already taken care of today, then say or ask what a friend would."
        } else {
            happened = "The glasses saw the frame below \(ago) seconds ago, and its analysis flagged it. Nothing was found that links it to the user's intents, destination, calendar or belongings: unless you see such a link yourself, or it is a physical danger where they are walking, stay silent."
        }
        // Recorded a while ago (the phone was in the pocket, or the frame waited in a queue)
        // and only now looked at: it is still judged, as something from then.
        let late = now.timeIntervalSince(n.seenAt) > 120
        let then = late ? "\nThis frame is from \(QueryEngine.promptTime(n.seenAt)), \(QueryEngine.agoText(now.timeIntervalSince(n.seenAt))) ago: it was recorded then and is only being looked at now. If it still matters (something left on and not seen switched off since, a deadline not yet passed, an intent still open), say it as something you saw then, with its time; if its moment has passed, stay silent." : ""
        await judge(happened: happened + then, record: record, related: related, candidates: candidates, jpeg: n.jpeg,
                    recordID: n.recordID, late: late, now: now)
    }

    /// Open intents whose "on seeing" cue this record may be (embedding first, reranker for the
    /// close ones; the same gates as Muisti Turva's rule matching).
    private func matching(_ n: EnrichmentWorker.Noticed, now: Date = Date()) async -> [Intent] {
        guard let vector = n.vector else { return [] }
        var close: [(intent: Intent, sight: String, cosine: Double)] = []
        for intent in intents where intent.status == .open && !intent.isSnoozed(now) && !policy.isMuted("", intentID: intent.id) {
            var sight = intent.cue.sight
            if sight == nil, intent.kind == .destination, intent.coordinate == nil {
                sight = "A sign, entrance or building of \(intent.placeName ?? intent.text)"
            }
            guard let sight else { continue }
            if cueVectors[sight] == nil { cueVectors[sight] = try? await ai.embed(sight, as: .query) }
            guard let query = cueVectors[sight] else { continue }
            let cosine = Self.cosine(query, vector)
            if cosine >= 0.15 { close.append((intent, sight, cosine)) }
        }
        var out: [Intent] = []
        for item in close.sorted(by: { $0.cosine > $1.cosine }).prefix(4) {
            let score = (try? await ai.rerank(query: item.sight, passages: [String(n.passage.prefix(2500))], paced: true))?.first
            // Calibrated on the 14 Nov agent eval (one "a pharmacy" intent, 45 frames): the five
            // pharmacy frames scored −2.48…−2.94, every other frame −3.21 or lower; embedding
            // alone overlaps (pharmacies 0.33–0.54, others up to 0.38), so it only decides when
            // there is no reranker.
            let keep = score.map { $0 >= -3.1 } ?? (item.cosine >= 0.30)
            Trace.note("agent cue \(item.intent.id) ↔ #\(n.recordID): cosine \(String(format: "%.2f", item.cosine)), rerank \(score.map { String(format: "%.2f", $0) } ?? "-") → \(keep ? "candidate" : "no")")
            if keep { out.append(item.intent) }
        }
        return out
    }

    /// Which of the standing cues this record is, if any.
    private func standingMatch(_ n: EnrichmentWorker.Noticed) async -> String? {
        guard let vector = n.vector else { return nil }
        var best: (id: String, sight: String, cosine: Double)?
        for cue in Self.standing {
            if cueVectors[cue.sight] == nil { cueVectors[cue.sight] = try? await ai.embed(cue.sight, as: .query) }
            guard let query = cueVectors[cue.sight] else { continue }
            let cosine = Self.cosine(query, vector)
            if cosine >= 0.25, cosine > (best?.cosine ?? 0) { best = (cue.id, cue.sight, cosine) }
        }
        guard let best else { return nil }
        let score = (try? await ai.rerank(query: best.sight, passages: [String(n.passage.prefix(2500))], paced: true))?.first
        let keep = score.map { $0 >= -3.1 } ?? (best.cosine >= 0.35)
        Trace.note("agent standing \(best.id) ↔ #\(n.recordID): cosine \(String(format: "%.2f", best.cosine)), rerank \(score.map { String(format: "%.2f", $0) } ?? "-") → \(keep ? "look" : "no")")
        return keep ? best.id : nil
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }

    /// Earlier records about the same thing (the same product elsewhere, the same place another
    /// day): what makes "it was cheaper yesterday" possible without any price code.
    private func related(to n: EnrichmentWorker.Noticed) async -> [String] {
        guard let vector = n.vector else { return [] }
        let hits = await memory.search(MemorySearch(keywords: n.title.map { [$0] } ?? [], embedding: vector, limit: 12))
        return hits.map(\.record)
            .filter { $0.id != n.recordID && $0.seenAt < n.seenAt.addingTimeInterval(-600) }
            .prefix(3)
            .sorted { $0.seenAt < $1.seenAt }
            .map { "id \($0.id), seen \(QueryEngine.promptTime($0.seenAt))\($0.street.map { ", \($0)" } ?? "")\n\(EnrichmentWorker.passage(for: $0).prefix(600))" }
    }

    // MARK: The judgement and what follows from it

    private func judge(happened: String, record: String? = nil, related: [String] = [], candidates: [Intent] = [], jpeg: Data? = nil,
                       recordID: Int64? = nil, late: Bool = false, expires: Date? = nil, now: Date = Date()) async {
        guard await ai.hasKey else { return }
        let started = ContinuousClock.now
        let asked = Notice.user(situation: await situationWithTalk(now: now), happened: happened, record: record, related: related, candidates: candidates)
        guard let outcome = await Notice.judge(ai, user: asked, jpeg: jpeg, language: language(), recordID: recordID, toolbox: toolbox) else { return }
        let user = asked + outcome.lookedUp
        judgements += 1
        let ms = (ContinuousClock.now - started).milliseconds
        for id in outcome.completed {
            // "Whenever you see…" is the user's to end, not the model's.
            if let intent = intents.first(where: { $0.id == id }), intent.kind != .watch { await close(intent, as: .done) }
        }
        for var note in outcome.notes {
            await resolvePlace(&note)
            await save(note)
            Trace.note("agent note \(note.id): \(note.text.prefix(60))\(Self.cueText(note.cue))")
        }
        for place in outcome.places {
            if let fix = location.freshFix(maxAge: 120) { await savePlace(name: place.name, at: fix, detail: place.detail) }
        }
        let frame: URL? = await {
            guard let recordID, let record = await memory.record(id: recordID) else { return nil }
            return memory.frameURL(record)
        }()
        if let offer = outcome.offer, let start = Cue(at: offer.start).nextDue(after: now), start > now {
            // Only the frame's own text counts for the date: the situation is full of other numbers.
            let dated = Notice.dateWritten(start, shown: (record ?? "") + "\n" + related.joined(separator: "\n"))
            if let why = Notice.check(offer.question, shown: user) ?? (dated ? nil : "the event's day and hour are not written in the record") {
                await logSilent(topic: "calendar_offer", text: offer.question, reason: "refused: \(why)", recordID: recordID)
            } else {
                pending = .calendar(title: offer.title, start: start, minutes: offer.minutes ?? 60, location: offer.location)
                let level = await policy.submit(Proposal(topic: "calendar_offer", urgency: .timely, text: offer.question, language: language(),
                                                         expectsReply: true, frame: frame, recordID: recordID, expires: expires, late: late), now: now)
                if level < .spoken { pending = nil }   // not asked aloud: nothing is waiting for a yes
            }
            lastJudgement = "\(ms) ms · offer: \(offer.question)"
            return
        }
        guard let telling = outcome.telling else {
            lastJudgement = "\(ms) ms · silent: \(outcome.silentReason ?? "-")"
            // The log says what it was about (the record's first line), not the prompt.
            let about = record?.split(separator: "\n").dropFirst().first.map(String.init) ?? String(happened.prefix(120))
            await logSilent(topic: candidates.first.map { _ in "reminder" } ?? "notice", text: about, reason: "model: \(outcome.silentReason ?? "-")", recordID: recordID)
            return
        }
        // The one intent this judgement was about, when the model left its id out or misspelt it.
        let intent = telling.intentID.flatMap { id in intents.first { $0.id == id } }
            ?? (candidates.count == 1 ? intents.first { $0.id == candidates[0].id } : nil)
        var text = telling.text
        // Said about a frame the user is looking at right now: that is for now, whatever the model called it.
        let urgency: Urgency = recordID != nil && !late ? .timely : telling.urgency
        if let why = Notice.check(telling.text, shown: user, quote: telling.quote) {
            await logSilent(topic: telling.topic, text: telling.text, reason: "refused: \(why)", recordID: recordID)
            // The model's sentence does not hold up, but it is the moment for the intent: the
            // sentence written when the intent was made is said instead, nothing more.
            guard let own = intent?.say else {
                lastJudgement = "\(ms) ms · refused (\(why)): \(telling.text)"
                return
            }
            text = own
        }
        lastJudgement = "\(ms) ms · \(urgency.rawValue) [\(telling.topic)]: \(text)"
        await policy.submit(Proposal(topic: intent == nil ? telling.topic : "reminder", urgency: urgency, text: text,
                                     language: language(), expectsReply: telling.expectsReply, frame: frame, intentID: intent?.id,
                                     recordID: recordID, expires: expires, late: late), now: now)
        // "Whenever you see…" stays open however final the model thought this was.
        if let intent { await broughtUp(intent, done: telling.intentDone && intent.kind != .watch, now: now) }
    }

    private func logSilent(topic: String, text: String, reason: String, recordID: Int64?) async {
        Trace.note("agent silent [\(topic)] \(reason)")
        await dialog?.append(DialogTurn(at: Date(), speaker: .note, text: "stayed silent about \(topic): \(reason.prefix(200))",
                                        recordIDs: recordID.map { $0 > 0 ? [$0] : [] } ?? []))
        await store.insert(Intervention(source: "agent", topic: topic, urgency: .fyi, level: .silent, text: String(text.prefix(300)),
                                        recordID: recordID, reason: reason))
    }

    /// An intent was just brought up: finished, or not again for a while.
    private func broughtUp(_ intent: Intent, done: Bool, now: Date) async {
        var updated = intent
        updated.firedAt = now
        updated.fireCount += 1
        if done {
            await close(updated, as: .done)
        } else {
            updated.snoozeUntil = now.addingTimeInterval(Self.snooze)
            await save(updated)
        }
    }

    // MARK: Triggers computed on the phone

    func tick(now: Date = Date()) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        await policy.release(now: now)
        guard settings.enabled else { return }
        if settings.calendar { calendar.refresh(now: now) }
        await timeCues(now: now)
        let fix = location.freshFix(maxAge: 30, now: now)
        if let fix {
            await homeCues(fix, now: now)
            await placeCues(fix, now: now)
            if settings.navigation {
                await followDestination(fix, now: now)
                await watchParking(fix, now: now)
            }
        }
        await calendarCues(now: now)
        await review(now: now)
        await eveningDigest(now: now)
    }

    /// Reminders with a time. Spoken as written when the intent was made (no model call).
    private func timeCues(now: Date) async {
        for intent in intents where intent.status == .open && !intent.isSnoozed(now) {
            guard intent.cue.at != nil || intent.cue.daily != nil,
                  let due = intent.cue.nextDue(after: intent.firedAt ?? intent.createdAt) else { continue }
            // Muisti is running and will say it: the system's copy of the reminder is not needed.
            if due.timeIntervalSince(now) < 25 {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["agent.time.\(intent.id)"])
            }
            guard due <= now else { continue }
            var updated = intent
            updated.firedAt = now
            updated.fireCount += 1
            // Long overdue (Muisti was closed; the phone's own notification covered it): not said again.
            if now.timeIntervalSince(due) < 30 * 60 {
                await policy.submit(Proposal(topic: "reminder", urgency: .timely, text: intent.say ?? intent.text, language: intent.language ?? language(),
                                             intentID: intent.id, expires: due.addingTimeInterval(30 * 60)), now: now)
            }
            let once = intent.cue.daily == nil
            if once, intent.cue.place == nil, intent.cue.sight == nil, intent.cue.on == nil {
                await close(updated, as: .done)
            } else {
                if once { updated.cue.at = nil }
                await save(updated)
            }
        }
    }

    private func homeCues(_ fix: LocationFix, now: Date) async {
        guard let home else { return }
        let distance = home.location.distance(from: fix.clLocation)
        let slack = min(fix.accuracy, 100)
        let atHome: Bool? = distance <= home.radius + slack ? true : (distance > home.radius + slack + 50 ? false : nil)
        guard let atHome else { return }
        defer { wasHome = atHome }
        guard let before = wasHome, before != atHome else { return }
        let event = atHome ? "arriving_home" : "leaving_home"
        for intent in intents where intent.status == .open && intent.cue.on == event && !intent.isSnoozed(now) {
            await policy.submit(Proposal(topic: "reminder", urgency: .timely, text: intent.say ?? intent.text, language: intent.language ?? language(),
                                         intentID: intent.id, expires: now.addingTimeInterval(10 * 60)), now: now)
            await broughtUp(intent, done: intent.cue.daily == nil && intent.kind != .watch, now: now)
        }
    }

    /// Intents waiting for a place: one of the user's own, or (with map look-ups allowed) any
    /// place the words describe that is now close by.
    private func placeCues(_ fix: LocationFix, now: Date) async {
        guard fix.accuracy <= 65 else { return }
        for intent in intents where intent.status == .open && intent.kind != .destination && intent.kind != .parking
            && intent.cue.place != nil && !intent.isSnoozed(now) {
            guard let words = intent.cue.place else { continue }
            var near: (name: String, coordinate: CLLocationCoordinate2D, meters: Double)?
            let named = (places + (home.map { [$0] } ?? [])).first { $0.name.caseInsensitiveCompare(words) == .orderedSame }
            if let named {
                let meters = named.location.distance(from: fix.clLocation)
                if meters <= named.radius + min(fix.accuracy, 50) { near = (named.name, named.location.coordinate, meters) }
            } else if settings.mapSearch {
                // Looked up again every 150 m walked (and at most every 30 s): Apple limits these.
                var current = intent
                let due = placeLookups[intent.id].map { $0.at.distance(from: fix.clLocation) >= 150 && now.timeIntervalSince($0.when) >= 30 } ?? true
                if due {
                    placeLookups[intent.id] = (fix.clLocation, now)
                    if let first = await Places.search(words, near: fix.clLocation.coordinate, radius: 400).first,
                       intent.coordinate.map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: first.location) > 30 }) ?? true {
                        // The nearest match is also what the phone's own location reminder watches for.
                        current.latitude = first.latitude
                        current.longitude = first.longitude
                        current.placeName = first.name
                        await save(current)
                    }
                }
                // Between look-ups the last match found is still watched: walking up to it counts.
                if let coordinate = current.coordinate {
                    let meters = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: fix.clLocation)
                    if meters <= Self.nearPlace { near = (current.placeName ?? words, coordinate, meters) }
                }
            }
            guard let near else { continue }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["agent.place.\(intent.id)"])
            let side = Places.relative(bearing: Places.bearing(from: fix.clLocation.coordinate, to: near.coordinate), course: fix.validCourse)
            await judge(happened: "The user is now \(distanceText(near.meters)) from “\(near.name)” (\(side)), which fits the place intent \(intent.id) is waiting for (“\(words)”). This is the moment to bring that intent up unless the situation says otherwise.",
                        candidates: [intent], expires: now.addingTimeInterval(5 * 60), now: now)
            // Whatever was decided: not asked again at every step past the same place.
            if let current = intents.first(where: { $0.id == intent.id }), current.status == .open, !current.isSnoozed(now) {
                var updated = current
                updated.snoozeUntil = now.addingTimeInterval(Self.snooze)
                await save(updated)
            }
        }
    }

    private func followDestination(_ fix: LocationFix, now: Date) async {
        guard var target = destination else { return }
        if navigator.targetID != target.id { navigator.reset(target: target.id) }
        if target.coordinate == nil {
            // Not found when it was said (no fix yet, or no such place nearby): tried again every minute.
            if let last = placeLookups[target.id], now.timeIntervalSince(last.when) < 60 { return }
            placeLookups[target.id] = (fix.clLocation, now)
            await resolvePlace(&target)
            guard target.coordinate != nil else { return }
            await save(target)
        }
        guard let coordinate = target.coordinate else { return }
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: fix.clLocation)
        let moving = (fix.validSpeed ?? 0) >= 0.5 || motion.activity == .walking || motion.activity == .running
        guard let event = navigator.update(distance: distance, accuracy: fix.accuracy, moving: moving, now: now) else { return }
        let name = target.placeName ?? target.text
        let side = Places.relative(bearing: Places.bearing(from: fix.clLocation.coordinate, to: coordinate), course: fix.validCourse)
        switch event {
        case .arrived(let meters):
            await judge(happened: "The user has reached their destination “\(name)”: it is \(distanceText(meters)) away (\(side)). Tell them in a few words that they are there.",
                        candidates: [target], expires: now.addingTimeInterval(120), now: now)
            if let current = intents.first(where: { $0.id == target.id }), current.status == .open { await close(current, as: .done) }
            navigator.reset(target: nil)
            route = nil
        case .walkingAway where route != nil:
            break   // with a route, leaving it is handled turn by turn (`navigationFix`)
        case .walkingAway(let meters, let closest, let seconds):
            await judge(happened: "The user said they are going to “\(name)” but has been moving away from it for about \(seconds) seconds: it is now \(distanceText(meters)) away, \(side); the closest they got was \(distanceText(closest)). Tell them which way it is, unless the situation shows they changed their plan.",
                        candidates: [target], expires: now.addingTimeInterval(90), now: now)
            // `judge` snoozes an intent it brings up; a destination keeps being followed.
            if var current = intents.first(where: { $0.id == target.id }), current.status == .open {
                current.snoozeUntil = nil
                await save(current)
            }
        }
    }

    // MARK: Turn by turn

    private static let lengthFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    private static func spokenDistance(_ meters: Double) -> String {
        let rounded = meters < 1000 ? (meters / 10).rounded() * 10 : (meters / 100).rounded() * 100
        return lengthFormatter.string(from: Measurement(value: rounded, unit: UnitLength.meters))
    }

    /// Asks Apple Maps for a walking route to the destination and, when asked to, says how far
    /// it is and what to do first.
    private func planRoute(announce: Bool, rerouting: Bool = false) async {
        guard settings.navigation, settings.mapSearch, !routeBusy, let target = destination, let coordinate = target.coordinate,
              let fix = location.freshFix(maxAge: 60) else { return }
        routeBusy = true
        defer { routeBusy = false }
        let name = target.placeName ?? target.text
        guard let planned = await RouteGuide.plan(from: fix.clLocation.coordinate, to: coordinate, name: name) else {
            Trace.note("agent route: none to “\(name)”")
            return
        }
        guard destination?.id == target.id else { return }
        route = planned
        Trace.note("agent route to “\(name)”: \(Int(planned.meters)) m, \(Int(planned.seconds / 60)) min, \(planned.steps.count) steps")
        guard announce else { return }
        let minutes = max(1, Int((planned.seconds / 60).rounded()))
        let summary = rerouting
            ? String(localized: "New route: \(Self.spokenDistance(planned.meters)), \(minutes) min.")
            : String(localized: "\(name): \(Self.spokenDistance(planned.meters)), \(minutes) min on foot.")
        await policy.submit(Proposal(topic: "navigation", urgency: .timely, text: [summary, planned.firstInstruction].compactMap { $0 }.joined(separator: " "),
                                     language: language(), intentID: target.id, expected: true))
    }

    /// Every GPS fix while a route is being followed: the next turn as the user comes up to it,
    /// a new route when they have left this one, and arrival.
    func navigationFix(_ fix: LocationFix) async {
        guard settings.enabled, settings.navigation, let target = destination, let coordinate = target.coordinate else { return }
        let here = fix.clLocation
        if here.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= Navigator.arriveWithin + 10 {
            await followDestination(fix, now: fix.timestamp)
            return
        }
        guard fix.accuracy <= 50 else { return }
        guard var guide = route else {
            // No route yet (said before there was a GPS fix, or the service did not answer): tried again.
            if lastReroute.map({ fix.timestamp.timeIntervalSince($0) > 30 }) ?? true {
                lastReroute = fix.timestamp
                await planRoute(announce: true)
            }
            return
        }
        let event = guide.update(here, accuracy: fix.accuracy)
        route = guide
        switch event {
        case .turn(let instruction, let meters):
            let text = meters > 12 ? String(localized: "In \(Self.spokenDistance(meters)): \(instruction)") : instruction
            await policy.submit(Proposal(topic: "navigation", urgency: .timely, text: text, language: language(), intentID: target.id,
                                         expires: fix.timestamp.addingTimeInterval(20), expected: true), now: fix.timestamp)
        case .offRoute(let meters):
            guard lastReroute.map({ fix.timestamp.timeIntervalSince($0) > 30 }) ?? true else { return }
            lastReroute = fix.timestamp
            Trace.note("agent route: \(Int(meters)) m off the route, asking for a new one")
            route = nil
            await planRoute(announce: true, rerouting: true)
        case nil:
            break
        }
    }

    /// Got out of a vehicle after a drive: where that happened is kept as "car", silently.
    private func watchParking(_ fix: LocationFix, now: Date) async {
        let activity = motion.activity
        if activity == .automotive {
            if drivingSince == nil { drivingSince = now }
            lastAutomotive = now
            return
        }
        guard let began = drivingSince, let last = lastAutomotive else { return }
        // A stop at a light is "stationary", not parked: only walking away ends the drive.
        if activity == .walking || activity == .running, now.timeIntervalSince(last) >= 20 {
            drivingSince = nil
            lastAutomotive = nil
            guard last.timeIntervalSince(began) >= 60 else { return }
            let spot = location.fix(near: last) ?? fix
            await savePlace(name: "car", at: spot, detail: nil)
            await logSilent(topic: "parking", text: "Parked; the spot was saved as “car”.", reason: "saved silently", recordID: nil)
        } else if now.timeIntervalSince(last) > 15 * 60 {
            drivingSince = nil
            lastAutomotive = nil
        }
    }

    private func calendarCues(now: Date) async {
        guard settings.calendar else { return }
        for event in calendar.upcoming where !event.allDay && !announcedEvents.contains(event.id) {
            let minutes = event.start.timeIntervalSince(now) / 60
            guard minutes > 0, minutes <= 15 else { continue }
            announcedEvents.insert(event.id)
            await judge(happened: "The user's calendar event “\(event.title)” starts at \(Cue.stamp(event.start).suffix(5)), in \(Int(minutes.rounded())) minutes\(event.location.map { ", at “\($0)”" } ?? ""). Say so only if it looks like they need the reminder (they are not there yet, or are heading elsewhere); when in doubt a short reminder is fine.",
                        expires: event.start.addingTimeInterval(5 * 60), now: now)
        }
    }

    /// The periodic look at everything together, while capturing, and only when something
    /// changed since the last one.
    func review(now: Date, forced: Bool = false) async {
        guard forced || isCapturing(), !judging else { return }
        let open = intents.filter { $0.status == .open && !$0.isSnoozed(now) }
        let habits = await habits(now: now)
        let missed = habits.filter { $0.overdue(at: now) }.map(\.what)
        guard forced || !open.isEmpty || (settings.calendar && !calendar.upcoming.isEmpty) || !missed.isEmpty else { return }
        var hasher = Hasher()
        hasher.combine(missed)
        hasher.combine(open.map(\.id))
        hasher.combine(calendar.upcoming.map(\.id))
        hasher.combine(location.area)
        hasher.combine(location.street)
        hasher.combine(wasHome)
        let state = hasher.finalize()
        if !forced, let last = lastReview, now.timeIntervalSince(last.at) < Self.reviewEvery || last.state == state { return }
        guard forced || lastReview != nil else {
            lastReview = (now, state)   // the first one only sets the baseline
            return
        }
        lastReview = (now, state)
        let recent = await memory.recent(limit: 6).map { r in
            "- id \(r.id), \(QueryEngine.promptTime(r.seenAt)): \(r.title)\(r.street.map { ", \($0)" } ?? "")"
        }
        let usual = habits.isEmpty ? "" : "\nWhat the user usually does, counted from the log of earlier days (a habit marked NOT today is the kind of thing a person living with them would mention, once, as a question; never as a fact that they did not do it — the glasses may simply not have seen it):\n" + Habits.lines(habits, now: now).joined(separator: "\n")
        await judge(happened: "Nothing in particular: this is Muisti's own periodic look at how the user's day is going (they have moved, the notes changed, or something they usually do by now has not been seen today). If something in the situation deserves a word by now — an intent whose moment is slipping, something they seem to have forgotten, a medicine or errand the notes show no trace of today, a habit missed — say it or ask; otherwise stay silent.\nLatest things the glasses saw:\n\(recent.joined(separator: "\n"))" + usual,
                    now: now)
    }

    // MARK: The day in a few sentences

    private static let digestSystem = """
    You write the summary of the user's day for Muisti, an assistant in their camera glasses. \
    Two to four short spoken sentences in the user's language, addressed to them: where they \
    were and what stood out, what is still open among their intents, and what is in their \
    calendar next; from the safety lines, only something that still matters tonight (a thing \
    left on, a medicine not yet taken). Only what the lines below say, with times and figures exactly as written; \
    nothing invented, no advice. Leave out whatever is empty (no open reminders, nothing in the \
    calendar) instead of saying so, and never use the words "intent", "record" or "frame". If \
    the lines hold nothing from today, say in one sentence that \
    there is nothing to sum up yet.
    """

    /// A short summary of today, from the episodes, the agent's notes and the calendar.
    func digest(now: Date = Date()) async -> String? {
        let today = Calendar.current.startOfDay(for: now)
        let episodes = await memory.episodes(limit: 40).filter { $0.endedAt >= today }.sorted { $0.startedAt < $1.startedAt }
        var lines = ["Current local time: \(QueryEngine.promptTime(now))", "Today's walks and visits, oldest first:"]
        lines += episodes.isEmpty ? ["(none)"] : episodes.map { e in
            "- \(Cue.stamp(e.startedAt).suffix(5))–\(Cue.stamp(e.endedAt).suffix(5))\(e.street.map { ", \($0)" } ?? ""): \(e.title ?? "untitled")\(e.summary.map { " — \($0)" } ?? "") (\(e.frameCount) frames)"
        }
        let finished = await store.intents(status: .done).filter { ($0.firedAt ?? $0.createdAt) >= today }
        if !finished.isEmpty { lines.append("Done today: " + finished.map(\.text).joined(separator: "; ")) }
        lines.append(promptContext(now: now))
        if let safety = await safetyContext?(), !safety.isEmpty { lines.append("Muisti Turva (safety rules, watched objects, safety log):\n" + safety) }
        let habits = await habits(now: now)
        if !habits.isEmpty { lines.append("What the user usually does (counted from earlier days):\n" + Habits.lines(habits, now: now).joined(separator: "\n")) }
        let user = lines.joined(separator: "\n")
        let ai = ai
        guard let text = await withTimeout(seconds: 20, { try await ai.chat(system: Self.digestSystem, user: user, maxTokens: 300, temperature: 0.2) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let why = Notice.check(text, shown: user) {
            Trace.note("agent digest refused (\(why))")
            return nil
        }
        return text
    }

    private func eveningDigest(now: Date) async {
        guard settings.eveningDigest, Calendar.current.component(.hour, from: now) == settings.digestHour else { return }
        let day = String(Cue.stamp(now).prefix(10))
        guard UserDefaults.standard.string(forKey: "agent.digestDay") != day else { return }
        UserDefaults.standard.set(day, forKey: "agent.digestDay")
        guard await memory.episodes(limit: 5).contains(where: { $0.endedAt >= Calendar.current.startOfDay(for: now) }),
              let text = await digest(now: now) else { return }
        await policy.submit(Proposal(topic: "day_summary", urgency: .useful, text: text, language: language()), now: now)
    }
}
