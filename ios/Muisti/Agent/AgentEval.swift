#if DEBUG
import CoreLocation
import Foundation

/// Agent evaluation on the simulator (DEBUG only), against the memory already in the app:
/// - what the turn model does with agent requests (which tool, what ends up stored);
/// - the phone-side triggers and the policy, with a clock and positions made up here;
/// - noticing: frames from the memory are shown to the agent as if just seen — the ones an
///   intent waits for must be brought up, the rest must stay silent (false alarms counted).
/// Writes `Documents/agent_result.txt` and `AGENT` log lines.
@MainActor
enum AgentEval {
    private static var lines: [String] = []
    private static var passed = 0, total = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { passed += 1 }
        let line = "\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " · \(detail)")"
        lines.append(line)
        Log.pipeline.info("AGENT \(line, privacy: .public)")
    }

    static func run(controller: CaptureController) async {
        lines = []; passed = 0; total = 0
        let agent = controller.agent
        let engine = controller.queryEngine
        await agent.deleteAll()
        agent.timerPaused = true
        defer { agent.timerPaused = false }
        // Nothing is spoken on the simulator: what would have been said is collected.
        var spoken: [String] = []
        let box = SpokenBox()
        agent.policy.speak = { text, _, _, _, _ in box.add(text) }
        agent.policy.chime = {}
        agent.policy.notify = { _, _, _ in }
        agent.settings.enabled = true
        agent.settings.noticing = true
        agent.settings.quietFromHour = 0
        agent.settings.quietToHour = 0

        // 1. Turns: which tool, and what is kept.
        struct Turn { let say: String; let tool: String; var after: (@MainActor (AgentCenter) -> (Bool, String))? = nil }
        let turns: [Turn] = [
            Turn(say: "Remind me to buy milk", tool: "remember_intent") { a in
                let i = a.intents.last
                return (i != nil && (i?.cue.place != nil || i?.cue.sight != nil), "cue \(String(describing: i?.cue))")
            },
            Turn(say: "What did I want to buy?", tool: "search_memory"),
            Turn(say: "I'm going to the pharmacy now", tool: "set_destination") { a in
                (a.intents.contains { $0.kind == .destination }, "destination kept")
            },
            Turn(say: "Never mind, I'm not going there anymore", tool: "cancel_destination") { a in
                (!a.intents.contains { $0.kind == .destination }, "destination dropped")
            },
            Turn(say: "My car is a blue Toyota", tool: "remember_fact") { a in (a.facts.count == 1, "\(a.facts.count) facts") },
            Turn(say: "Warn me if I leave the stove on when I go out", tool: "create_rule"),
            Turn(say: "No, that's not right", tool: "cancel_pending"),
            Turn(say: "Yarın sabah dokuzda dişçiyi aramayı hatırlat", tool: "remember_intent") { a in
                let i = a.intents.last
                return (i?.cue.at != nil || i?.cue.daily != nil, "cue \(String(describing: i?.cue))")
            },
            Turn(say: "Tell me whenever you see a pharmacy, I need to pick up my prescription", tool: "remember_intent") { a in
                (a.intents.last?.cue.sight != nil || a.intents.last?.cue.place != nil, "cue \(String(describing: a.intents.last?.cue))")
            },
            Turn(say: "I bought the milk", tool: "complete_intent") { a in
                (!a.intents.contains { $0.text.lowercased().contains("milk") }, "\(a.intents.count) open")
            },
            Turn(say: "How was my day?", tool: "summarize_day"),
            Turn(say: "What time is it in Tokyo usually compared to Helsinki?", tool: "reply"),
            Turn(say: "What was the phone number of the Old World food truck?", tool: "search_memory"),
        ]
        await engine.clearConversation()
        for turn in turns {
            let result = await engine.ask(turn.say, location: nil)
            var reply = result.answer
            if let command = result.agent, let own = await agent.handle(command) { reply = own }
            if let command = result.safety { _ = await controller.safety.handle(command) }
            await engine.noteExchange(question: turn.say, answer: reply)
            let trace = result.trace ?? ""
            let did = trace.contains("tool \(turn.tool)") || (turn.tool == "reply" && trace.contains("turn: reply"))
            let state = turn.after?(agent)
            check("turn “\(turn.say)” → \(turn.tool)", did && (state?.0 ?? true),
                  "\(trace.split(separator: "·").first.map(String.init) ?? "-")\(state.map { " · \($0.1)" } ?? "") · “\(reply.prefix(90))” · \(result.latencyMs) ms")
        }

        // 2. A reminder with a time: said when it is due, once.
        box.clear()
        let now = Date()
        _ = await agent.handle(.remember(text: "call the dentist", say: "You wanted to call the dentist.", kind: .reminder,
                                         cue: Cue(at: Cue.stamp(now.addingTimeInterval(120)))), now: now)
        await agent.tick(now: now.addingTimeInterval(20))
        let early = box.all.count
        await agent.tick(now: now.addingTimeInterval(185))
        await agent.tick(now: now.addingTimeInterval(200))
        check("time cue: silent before, said once when due", early == 0 && box.all.count == 1, "said \(box.all)")

        // 3. Policy: budget, gap, mute, safety (made-up clock).
        box.clear()
        await agent.store.deleteAll()
        await agent.reload()
        agent.settings.dailySpokenBudget = 3
        agent.settings.minGapMinutes = 10
        var levels: [InterventionLevel] = []
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        for i in 0..<5 {
            levels.append(await agent.policy.submit(Proposal(topic: "topic_\(i)", urgency: .timely, text: "note \(i)"), now: noon.addingTimeInterval(Double(i) * 11 * 60)))
        }
        check("policy: budget of 3 spoken, then notifications", levels == [.spoken, .spoken, .spoken, .notification, .notification], "\(levels.map(\.rawValue))")
        let gap = await agent.policy.submit(Proposal(topic: "gap", urgency: .timely, text: "too soon"), now: noon.addingTimeInterval(60))
        check("policy: within the gap → not spoken", gap < .spoken, "level \(gap.rawValue)")
        let safety = await agent.policy.submit(Proposal(source: "safety", topic: "safety", urgency: .safety, text: "stove"), now: noon.addingTimeInterval(120))
        check("policy: safety always spoken", safety == .spoken)
        await agent.policy.mute(topic: "prices", minutes: nil)
        let muted = await agent.policy.submit(Proposal(topic: "prices", urgency: .timely, text: "cheaper elsewhere"), now: noon.addingTimeInterval(3 * 3600))
        check("policy: muted topic stays silent", muted == .silent)
        let useful = await agent.policy.submit(Proposal(topic: "other", urgency: .useful, text: "fyi"), now: noon.addingTimeInterval(3 * 3600))
        check("policy: useful → short sound + notification", useful == .chime)

        // 4. Navigation arithmetic.
        var nav = Navigator()
        nav.reset(target: "x")
        var events: [Navigator.Event] = []
        var t = now
        for d in stride(from: 400.0, through: 200, by: -20) { if let e = nav.update(distance: d, accuracy: 10, moving: true, now: t) { events.append(e) }; t.addTimeInterval(10) }
        check("navigator: approaching says nothing", events.isEmpty)
        for d in stride(from: 215.0, through: 330, by: 15) { if let e = nav.update(distance: d, accuracy: 10, moving: true, now: t) { events.append(e) }; t.addTimeInterval(10) }
        let away = events.contains { if case .walkingAway = $0 { return true } else { return false } }
        check("navigator: walking away is noticed once", away && events.count == 1, "\(events)")
        var arrive = Navigator()
        arrive.reset(target: "y")
        check("navigator: arrival", arrive.update(distance: 20, accuracy: 10, moving: true, now: t) == .arrived(distance: 20))

        // `--agent-quick`: the two long steps over the stored frames are left out.
        if !ProcessInfo.processInfo.arguments.contains("--agent-quick") {
        // 5. Noticing: frames from the memory, as if just seen.
        await agent.store.deleteAll()
        await agent.reload()
        agent.settings.dailySpokenBudget = 1000   // every showing is its own moment: no budget, no gap
        agent.settings.minGapMinutes = 0
        box.clear()
        _ = await agent.handle(.remember(text: "pick up my prescription", say: "You wanted to pick up your prescription.", kind: .watch,
                                         cue: Cue(sight: "A pharmacy or drugstore: its sign, entrance or counter.")))
        let records = await controller.store.recent(limit: 400).filter { $0.status == .enriched }
        let pharmacies = records.filter { r in
            let text = EnrichmentWorker.passage(for: r).lowercased()
            return text.contains("pharmacy") || text.contains("apteekki") || text.contains("eczane")
        }
        let others = records.filter { r in !pharmacies.contains { $0.id == r.id } }
        var asked = 0, hit = 0, falseAlarms = 0, judged = 0
        var times: [Int] = []
        func show(_ r: MemoryRecord) async -> Bool {
            let passage = EnrichmentWorker.passage(for: r)
            guard let jpeg = try? Data(contentsOf: controller.store.frameURL(r)),
                  let vector = try? await controller.ai.embed(passage, as: .passage) else { return false }
            // Every showing is a fresh moment: no snooze or pause carried over from the one before.
            for var intent in agent.intents where intent.snoozeUntil != nil { intent.snoozeUntil = nil; await agent.store.save(intent) }
            await agent.reload()
            let before = box.all.count, calls = agent.judgements
            let began = ContinuousClock.now
            await agent.noticed(.init(recordID: r.id, seenAt: Date(), title: r.name ?? r.kind, passage: passage, vector: vector, jpeg: jpeg,
                                      attention: "none", reason: nil))
            if agent.judgements > calls { judged += 1; times.append((ContinuousClock.now - began).milliseconds) }
            let said = box.all.count > before
            Log.pipeline.info("AGENT notice #\(r.id) \(r.title, privacy: .public) → \(said ? "SAID: \(box.all.last ?? "")" : "silent", privacy: .public) · \(agent.lastJudgement.prefix(120), privacy: .public)")
            return said
        }
        for r in pharmacies.prefix(6) { asked += 1; if await show(r) { hit += 1 } }
        let negatives = Array(others.shuffled().prefix(40))
        for r in negatives { if await show(r) { falseAlarms += 1 } }
        check("noticing: pharmacy frames bring the intent up", asked > 0 && hit * 3 >= asked * 2, "\(hit)/\(asked)")
        check("noticing: other frames stay silent", falseAlarms * 20 <= negatives.count, "\(falseAlarms) false alarms in \(negatives.count)")
        times.sort()
        lines.append("noticing: \(judged) of \(asked + negatives.count) frames reached the model · judge p50 \(times.isEmpty ? 0 : times[times.count / 2]) ms")

        // 6. The enrichment's own flag on unprompted frames (no intent): how often it flags,
        // and whether the judge then keeps quiet about ordinary signs.
        await agent.store.deleteAll()
        await agent.reload()
        box.clear()
        var flags: [String: Int] = [:]
        var saidUnprompted: [String] = []
        for r in others.shuffled().prefix(25) {
            guard let jpeg = try? Data(contentsOf: controller.store.frameURL(r)) else { continue }
            guard let extracted = try? await controller.ai.chatJSON(ExtractedRecord.self, system: MemoryPrompts.extractionSystem,
                                                                    user: MemoryPrompts.extractionUser(ocr: r.ocrText), image: .init(jpeg: jpeg),
                                                                    jsonSchema: MemoryPrompts.extractionSchema, schemaName: "memory_record",
                                                                    maxTokens: 2500, temperature: 0) else { continue }
            let flag = extracted.attention ?? "none"
            flags[flag, default: 0] += 1
            guard flag != "none" else { continue }
            let passage = EnrichmentWorker.passage(for: r)
            let vector = try? await controller.ai.embed(passage, as: .passage)
            await agent.store.delete(since: Date().addingTimeInterval(-5))
            await agent.reload()
            let before = box.all.count
            await agent.noticed(.init(recordID: r.id, seenAt: Date(), title: r.name ?? r.kind, passage: passage, vector: vector, jpeg: jpeg,
                                      attention: flag, reason: extracted.attention_reason))
            let said = box.all.count > before
            if said { saidUnprompted.append("#\(r.id) [\(flag)] \(box.all.last ?? "")") }
            Log.pipeline.info("AGENT flag #\(r.id) [\(flag, privacy: .public)] \(extracted.attention_reason ?? "-", privacy: .public) → \(agent.lastJudgement.prefix(140), privacy: .public)")
        }
        lines.append("flags on 25 ordinary frames: \(flags.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        lines.append("spoken unprompted: \(saidUnprompted.count)" + saidUnprompted.map { "\n  \($0)" }.joined())
        _ = spoken
        }

        // 7. Initiative: photos nobody gave a rule or reminder for (`Documents/agentset/`). The
        // file name says what is expected: "speak_…" (Muisti should say or ask something by
        // itself) or "quiet_…".
        await agent.store.deleteAll()
        await agent.reload()
        box.clear()
        agent.policy.chime = { box.add("(chime)") }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let files = try? FileManager.default.contentsOfDirectory(at: documents.appendingPathComponent("agentset"), includingPropertiesForKeys: nil) {
            for file in files.filter({ $0.pathExtension == "jpg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let raw = try? Data(contentsOf: file), let prepared = await SafetyFrame.prepare(raw, maxPixel: 1536, fromPipeline: false),
                      let extracted = try? await controller.ai.chatJSON(ExtractedRecord.self, system: MemoryPrompts.extractionSystem,
                                                                        user: MemoryPrompts.extractionUser(ocr: prepared.ocr), image: .init(jpeg: prepared.jpeg),
                                                                        jsonSchema: MemoryPrompts.extractionSchema, schemaName: "memory_record",
                                                                        maxTokens: 2500, temperature: 0) else {
                    lines.append("initiative \(file.lastPathComponent): could not be prepared")
                    continue
                }
                let passage = [extracted.kindLabel, extracted.name, extracted.caption, extracted.other_text, extracted.visualText, prepared.ocr]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                await agent.store.delete(since: Date().addingTimeInterval(-5))
                await agent.reload()
                let before = box.all.count
                let began = ContinuousClock.now
                let vector = try? await controller.ai.embed(passage, as: .passage)
                await agent.noticed(.init(recordID: -1, seenAt: Date(), title: extracted.name ?? extracted.kindLabel, passage: passage,
                                          vector: vector, jpeg: prepared.jpeg, attention: extracted.attention, reason: extracted.attention_reason))
                let said = box.all.count > before
                let wanted = file.lastPathComponent.hasPrefix("speak")
                check("initiative \(file.lastPathComponent)", said == wanted,
                      "flag \(extracted.attention ?? "-") · \(said ? "SAID: \(box.all.last ?? "")" : agent.lastJudgement) · \((ContinuousClock.now - began).milliseconds) ms")
            }
        }
        // 8. Places, with made-up GPS around Helsinki's central station (Apple Maps is really asked).
        await agent.deleteAll()
        agent.settings.dailySpokenBudget = 1000
        agent.settings.minGapMinutes = 0
        agent.settings.mapSearch = true
        agent.settings.navigation = true
        agent.policy.chime = {}
        box.clear()
        var clock = Date().addingTimeInterval(3600)
        func at(_ latitude: Double, _ longitude: Double, course: Double = -1, speed: Double = 1.3) async {
            clock = clock.addingTimeInterval(10)
            controller.location.inject(CLLocation(coordinate: .init(latitude: latitude, longitude: longitude), altitude: 10, horizontalAccuracy: 8,
                                                  verticalAccuracy: 8, course: course, speed: speed, timestamp: clock))
            await agent.tick(now: clock)
        }
        let base = CLLocationCoordinate2D(latitude: 60.1719, longitude: 24.9414)
        controller.motion.simulate(.walking)
        await at(base.latitude, base.longitude)
        _ = await agent.handle(.remember(text: "buy milk", say: "You wanted to buy milk.", kind: .todo, cue: Cue(place: "grocery store")), now: clock)
        await at(base.latitude, base.longitude)
        let shop = agent.intents.first { $0.text == "buy milk" }
        check("place cue: a grocery store is found on the map", shop?.coordinate != nil, "\(shop?.placeName ?? "-")")
        if let spot = shop?.coordinate {
            // Already said if the shop was within 90 m of the starting point; otherwise on walking up to it.
            if box.all.isEmpty { await at(spot.latitude + 0.00005, spot.longitude) }
            check("place cue: said when the user is near the shop", !box.all.isEmpty, box.all.last ?? agent.lastJudgement)
        }
        // A destination: found, walked away from, then reached.
        box.clear()
        await at(base.latitude, base.longitude)
        _ = await agent.handle(.setDestination("Kiasma"), now: clock)
        let goal = agent.intents.first { $0.kind == .destination }
        check("destination: found on the map", goal?.coordinate != nil, "\(goal?.placeName ?? "-")")
        if let target = goal?.coordinate {
            // Away from it, 15 m every 10 s, heading the opposite way.
            let away = Places.bearing(from: target, to: base)
            var saidAway = false
            for step in 1...10 {
                let meters = Double(step) * 15
                let lat = base.latitude + meters * cos(away * .pi / 180) / 111_320
                let lon = base.longitude + meters * sin(away * .pi / 180) / (111_320 * cos(base.latitude * .pi / 180))
                let before = box.all.count
                await at(lat, lon, course: away)
                if box.all.count > before { saidAway = true; break }
            }
            check("destination: walking away is said", saidAway, box.all.last ?? agent.lastJudgement)
            let before = box.all.count
            await at(target.latitude, target.longitude, course: (away + 180).truncatingRemainder(dividingBy: 360))
            check("destination: arrival is said and the destination closed",
                  box.all.count > before && !agent.intents.contains { $0.kind == .destination }, box.all.last ?? agent.lastJudgement)
        }
        // Parking: a drive, then walking away from the car.
        await agent.store.deletePlace("car")
        await agent.reload()
        controller.motion.simulate(.automotive)
        for i in 0..<8 { await at(base.latitude + Double(i) * 0.001, base.longitude, speed: 12) }
        controller.motion.simulate(.walking)
        for i in 0..<4 { await at(base.latitude + 0.007 + Double(i) * 0.0001, base.longitude) }
        check("parking: the spot is saved as “car”", agent.places.contains { $0.id == "car" }, agent.places.first { $0.id == "car" }?.detail ?? "-")
        check("parking: the notes say where the car is", agent.promptContext(now: clock).contains("- car (parked"))

        // 9. Calendar and notification buttons (real clock again: the made-up one is cleared away).
        await agent.deleteAll()
        controller.motion.simulate(.walking)
        box.clear()
        agent.settings.calendar = true
        let granted = await agent.calendar.requestRead()
        if granted {
            let start = Date().addingTimeInterval(9 * 60)
            _ = await agent.calendar.add(title: "Design review", start: start, minutes: 30, location: "Messukeskus hall 3", notes: "agent eval")
            agent.calendar.refresh(force: true)
            check("calendar: the event is read", agent.calendar.upcoming.contains { $0.title == "Design review" })
            await agent.tick(now: Date())
            check("calendar: an event 9 minutes away is brought up", !box.all.isEmpty, box.all.last ?? agent.lastJudgement)
        } else {
            lines.append("calendar: no access on this simulator, not tested")
        }
        agent.settings.calendar = false
        _ = await agent.handle(.remember(text: "water the plants", say: "You wanted to water the plants.", kind: .reminder, cue: Cue(daily: "07:30")))
        if let plants = agent.intents.first(where: { $0.text == "water the plants" }) {
            await agent.notificationAction(.later, intentID: plants.id, interventionID: nil)
            check("notification “Later”: the intent is put off", agent.intents.first { $0.id == plants.id }?.snoozeUntil != nil)
            await agent.notificationAction(.never, intentID: plants.id, interventionID: nil)
            check("notification “Don't tell me again”: dropped and muted",
                  !agent.intents.contains { $0.id == plants.id } && agent.policy.isMuted("", intentID: plants.id))
        }
        _ = await agent.handle(.remember(text: "post the letter", say: "You wanted to post the letter.", kind: .todo, cue: Cue(sight: "a mailbox")))
        if let letter = agent.intents.first(where: { $0.text == "post the letter" }) {
            await agent.notificationAction(.done, intentID: letter.id, interventionID: nil)
            check("notification “Done”: the intent is closed", !agent.intents.contains { $0.id == letter.id })
        }

        agent.settings.dailySpokenBudget = 40
        agent.settings.minGapMinutes = 2
        await agent.deleteAll()
        let summary = "AGENT SUMMARY \(passed)/\(total)"
        lines.insert(summary, at: 0)
        Log.pipeline.info("\(summary, privacy: .public)")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("agent_result.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// What the agent would have said aloud during the evaluation.
final class SpokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
    func clear() { lock.lock(); texts = []; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
}
#endif
