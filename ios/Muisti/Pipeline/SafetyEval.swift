#if DEBUG
import Foundation

/// Muisti Turva evaluation on the simulator (DEBUG only). Three parts:
/// A. the plan's scenarios through the real `SafetyMonitor` with injected frame readings
///    (rules, state machine, triggers; no network);
/// B. the frame model on real photos: `Documents/<folder>/manifest.json`
///    `[{"file", "stove": "on"|"not_on"|"any", "room"?, "allergens_in"?, "allergens_out"?}]`;
/// C. a spoken conversation through the answer model: creating, confirming, using and
///    deleting rules, telling Muisti things, asking about states.
/// Writes `Documents/<folder>/safety_result.txt` and `SAFETY` log lines.
@MainActor
enum SafetyEval {
    final class Spoken { var lines: [String] = [] }

    static func run(controller: CaptureController, folder: String) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        var report: [String] = []
        func log(_ line: String) {
            report.append(line)
            Log.pipeline.info("SAFETY \(line, privacy: .public)")
        }
        let args = ProcessInfo.processInfo.arguments
        let parts = args.first { $0.hasPrefix("--safety-parts=") }.map { String($0.dropFirst(15)) } ?? "ABC"
        if parts.contains("A") { await scenarios(controller: controller, log: log) }
        if parts.contains("B") { await perception(controller: controller, dir: dir, log: log) }
        if parts.contains("C") { await conversation(controller: controller, log: log) }
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("safety_result.txt"), atomically: true, encoding: .utf8)
        Log.pipeline.info("SAFETY DONE")
    }

    // MARK: A. Scenarios

    private static func rule(_ id: String, _ trigger: SafetyRule.Trigger, _ condition: SafetyRule.Condition, _ message: String,
                             watch: [String], confirm: String? = nil) -> SafetyRule {
        SafetyRule(id: id, summary: id, language: "en", watch: watch, trigger: trigger, condition: condition,
                   severity: .high, message: message, cooldown_min: 30, confirm_question: confirm)
    }

    static let stoveLeave = rule("stove_leave", .init(type: .context, event: "left_home"),
                                 .init(object: "stove", last_state: "on", not_followed_by: "off"),
                                 "I last saw the stove on at {last_seen_time} and did not see you turn it off.", watch: ["stove"])
    static let keysLeave = rule("keys_leave", .init(type: .context, event: "left_home"),
                                .init(object: "keys", seen_within_min: 120),
                                "I last saw your keys at {last_seen_time}, {place}.", watch: ["keys"])
    static let stoveIdle = rule("stove_idle", .init(type: .inactivity, object: "stove", state: "on", minutes: 20),
                                .init(object: "stove", last_state: "on"),
                                "The stove may have been on for a while; I last saw it on at {last_seen_time}.", watch: ["stove"])

    static func medRule(at time: Date) -> SafetyRule {
        rule("med_morning", .init(type: .schedule, time: SafetyMonitor.clock(time), grace_min: 30),
             .init(object: "medication:enalapril", action: "took"),
             "I did not see you take your morning medicine.", watch: ["medication:enalapril"],
             confirm: "Did you take your Enalapril?")
    }

    static let secondDose = rule("med_second", .init(type: .event, object: "medication:enalapril", state: "in_hand"),
                                 .init(object: "medication:enalapril", action: "took", count_at_least: 1),
                                 "It looks like you already took this medicine today at {action_time}.", watch: ["medication:enalapril"])

    private static func stove(_ state: String, visible: Bool = true) -> SafetyObservation {
        SafetyObservation(room: "kitchen", hands_visible: true,
                          objects: [.init(name: "stove", visible: visible, state: state, location_hint: nil, evidence: "test")])
    }

    private static func scenarios(controller: CaptureController, log: (String) -> Void) async {
        let store = SafetyStore(fileName: "safety_eval.sqlite")
        let monitor = SafetyMonitor(store: store, ai: controller.ai, location: controller.location)
        let spoken = Spoken()
        monitor.announce = { text, _, _, _ in spoken.lines.append(text) }
        var passed = 0, total = 0

        func reset(_ rules: [SafetyRule]) async {
            await store.deleteAll()
            for r in await store.rules() { await store.deleteRule(r.id) }
            for r in rules { await store.save(r) }
            await monitor.reload()
            spoken.lines = []
        }
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            total += 1
            if ok { passed += 1 }
            log("A \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
        let now = Date()
        let t = { (minutes: Double) in now.addingTimeInterval(minutes * 60) }

        // 1. Stove turned on, user leaves → warning.
        await reset([stoveLeave])
        await monitor.apply(stove("on"), at: t(-10), frameFile: nil)
        await monitor.apply(stove("on"), at: t(-9.9), frameFile: nil)
        var said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("1 stove on, leave", said.count == 1 && said[0].contains(SafetyMonitor.clock(t(-9.9))), said.joined())

        // 1b. A single "on" reading is not enough.
        await reset([stoveLeave])
        await monitor.apply(stove("on"), at: t(-10), frameFile: nil)
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("1b one on-reading, leave", said.isEmpty, said.joined())

        // 2. On, then off, leave → nothing.
        await reset([stoveLeave])
        await monitor.apply(stove("on"), at: t(-10), frameFile: nil)
        await monitor.apply(stove("on"), at: t(-9.9), frameFile: nil)
        await monitor.apply(stove("off"), at: t(-5), frameFile: nil)
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("2 on then off, leave", said.isEmpty, said.joined())

        // 3. Stove never seen, leave → nothing.
        await reset([stoveLeave])
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("3 never seen, leave", said.isEmpty, said.joined())

        // 4. On, turning off not seen, user says "I turned it off" → nothing; source = user's words.
        await reset([stoveLeave])
        await monitor.apply(stove("on"), at: t(-10), frameFile: nil)
        await monitor.apply(stove("on"), at: t(-9.9), frameFile: nil)
        _ = await monitor.handle(.logEvent(object: "stove", kind: .state, value: "off"), now: t(-2))
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        let st = monitor.states.first { $0.object == "stove" }
        check("4 told off, leave", said.isEmpty && st?.source == .user_voice, "\(said.joined()) state=\(st?.state ?? "-") source=\(st?.source.rawValue ?? "-")")

        // 5. Medicine time passes without an intake → reminder.
        await reset([medRule(at: t(-40))])
        await monitor.tick(now: now)
        check("5 medicine reminder", spoken.lines.count == 1, spoken.lines.joined())
        spoken.lines = []
        await monitor.tick(now: now.addingTimeInterval(60))
        check("5b reminder only once", spoken.lines.isEmpty, spoken.lines.joined())

        // 6. Box in hand at medicine time → question → "yes" → box in hand again → second dose.
        await reset([medRule(at: t(-5)), secondDose])
        let inHand = SafetyObservation(room: "kitchen", hands_visible: true, objects: [
            .init(name: "medication:enalapril", visible: true, state: "in_hand", location_hint: nil, evidence: "box in hand")])
        await monitor.apply(inHand, at: now, frameFile: nil)
        let asked = spoken.lines
        _ = await monitor.handle(.confirm)
        spoken.lines = []
        await monitor.apply(inHand, at: now.addingTimeInterval(120), frameFile: nil)
        check("6a confirm question", asked == ["Did you take your Enalapril?"], asked.joined(separator: " | "))
        check("6b second dose", spoken.lines.count == 1 && spoken.lines[0].contains(SafetyMonitor.clock(now)), spoken.lines.joined())

        // 7. Keys put on the table, user leaves → where they were seen.
        await reset([keysLeave])
        let keys = SafetyObservation(room: "kitchen", hands_visible: false, objects: [
            .init(name: "keys", visible: true, state: "placed", location_hint: "on the kitchen table", evidence: "keys on table")])
        await monitor.apply(keys, at: t(-20), frameFile: nil)
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("7 keys left", said.count == 1 && said[0].contains("kitchen table"), said.joined())

        // 8. A stove on TV: the frame model reports it not visible → nothing.
        await reset([stoveLeave])
        await monitor.apply(stove("on", visible: false), at: t(-10), frameFile: nil)
        await monitor.apply(stove("on", visible: false), at: t(-9.9), frameFile: nil)
        said = await monitor.trigger(contextEvent: "left_home", source: .user_voice, at: now, speak: false)
        check("8 TV trap (as read)", said.isEmpty, said.joined())

        // 9. Inactivity: on, not looked at for 25 minutes → warning.
        await reset([stoveIdle])
        await monitor.apply(stove("on"), at: t(-26), frameFile: nil)
        await monitor.apply(stove("on"), at: t(-25.9), frameFile: nil)
        await monitor.tick(now: now)
        check("9 stove unattended", spoken.lines.count == 1, spoken.lines.joined())

        log("A SUMMARY \(passed)/\(total)")
        await store.deleteAll()
        for r in await store.rules() { await store.deleteRule(r.id) }
    }

    // MARK: B. Frame model on photos

    struct PhotoCase: Decodable {
        let file: String
        let stove: String
        let room: String?
        let allergens_in: [String]?
        let allergens_out: [String]?
    }

    private static func perception(controller: CaptureController, dir: URL, log: (String) -> Void) async {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let cases = try? JSONDecoder().decode([PhotoCase].self, from: data) else {
            log("B no manifest.json")
            return
        }
        let watched = ["stove", "keys", "medication:enalapril"]
        let allergens = ["milk", "gluten", "egg"]
        var stoveOK = 0, stoveTotal = 0, falseOn = 0, missedOn = 0, roomOK = 0, roomTotal = 0, labelOK = 0, labelTotal = 0
        var latencies: [Int] = []
        for c in cases {
            guard let jpeg = try? Data(contentsOf: dir.appendingPathComponent(c.file)) else { log("B missing \(c.file)"); continue }
            let started = ContinuousClock.now
            guard let copy = await Task.detached(operation: { SafetyFrame.prepare(jpeg) }).value else { log("B \(c.file): privacy copy failed"); continue }
            let obs: SafetyObservation
            do {
                obs = try await controller.ai.chatJSON(SafetyObservation.self, system: SafetyPrompts.observeSystem,
                                                       user: SafetyPrompts.observeUser(watched: watched, allergens: allergens, ocr: copy.ocr),
                                                       image: .init(jpeg: copy.jpeg), jsonSchema: SafetyPrompts.observeSchema,
                                                       schemaName: "observation", maxTokens: 500, temperature: 0.2)
            } catch {
                log("B \(c.file): model error \(error)")
                continue
            }
            latencies.append((ContinuousClock.now - started).milliseconds)
            let s = obs.objects.first { $0.name == "stove" }
            let state = (s?.visible ?? false) ? (s?.state ?? "unknown") : "not visible"
            var ok = true
            if c.stove != "any" {
                stoveTotal += 1
                let isOn = state == "on"
                ok = c.stove == "on" ? isOn : !isOn
                if ok { stoveOK += 1 } else if isOn { falseOn += 1 } else { missedOn += 1 }
            }
            if let room = c.room {
                roomTotal += 1
                if obs.room == room { roomOK += 1 } else { ok = false }
            }
            if c.allergens_in != nil || c.allergens_out != nil {
                labelTotal += 1
                let found = Set(obs.label?.allergens_found ?? [])
                let hit = (c.allergens_in ?? []).allSatisfy { a in found.contains { $0.contains(a) } }
                let clean = (c.allergens_out ?? []).allSatisfy { a in !found.contains { $0.contains(a) } }
                if hit && clean { labelOK += 1 } else { ok = false }
            }
            log("B \(ok ? "PASS" : "FAIL") \(c.file): stove=\(state) (want \(c.stove)) room=\(obs.room) label=\(obs.label.map { "\($0.allergens_found)" } ?? "-") evidence=\(s?.evidence ?? "-")")
        }
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        log("B SUMMARY stove \(stoveOK)/\(stoveTotal) (false on \(falseOn), missed on \(missedOn)) · room \(roomOK)/\(roomTotal) · labels \(labelOK)/\(labelTotal) · p50 \(p50) ms")
    }

    // MARK: C. Conversation through the answer model

    private static func conversation(controller: CaptureController, log: (String) -> Void) async {
        let safety = controller.safety
        await safety.store.deleteAll()
        for r in safety.rules { await safety.store.deleteRule(r.id) }
        await safety.reload()
        let voice = controller.voice
        var step = 0
        func say(_ text: String) async -> AskResult? {
            step += 1
            await voice.ask(text)
            guard let r = voice.history.first else { return nil }
            log("C \(step) “\(text)” → \(r.isCommand ? "[command]" : "[\(r.label.rawValue)]") \(r.answer) · \(r.trace ?? "")")
            return r
        }
        _ = await say("Warn me if I leave home and the stove is on.")
        log("C pending: \(safety.pending?.prompt ?? "none")")
        if case .rule(let r) = safety.pending { log("C rule: \(String(data: (try? JSONEncoder().encode(r)) ?? Data(), encoding: .utf8) ?? "")") }
        _ = await say("Yes.")
        _ = await say("Remind me to take my Enalapril every morning at 8.")
        if case .rule(let r) = safety.pending { log("C rule: \(String(data: (try? JSONEncoder().encode(r)) ?? Data(), encoding: .utf8) ?? "")") }
        _ = await say("Yes, that's right.")
        _ = await say("Uyar beni, aldığım ürünlerde süt varsa.")
        if case .rule(let r) = safety.pending { log("C rule: \(String(data: (try? JSONEncoder().encode(r)) ?? Data(), encoding: .utf8) ?? "")") }
        _ = await say("Evet.")
        log("C rules now: \(safety.rules.map(\.summary))")

        // Seen: stove on twice at 18:42 (today), as the frame model would report it.
        let at = Calendar.current.date(bySettingHour: 18, minute: 42, second: 0, of: Date()) ?? Date()
        let on = SafetyObservation(room: "kitchen", hands_visible: true,
                                   objects: [.init(name: "stove", visible: true, state: "on", location_hint: nil, evidence: "zone 2 display shows 7")])
        await safety.apply(on, at: at.addingTimeInterval(-30), frameFile: nil)
        await safety.apply(on, at: at, frameFile: nil)
        _ = await say("Did I turn off the stove?")
        _ = await say("I'm leaving now.")
        _ = await say("Not now.")
        _ = await say("I turned the stove off.")
        _ = await say("Did I turn off the stove?")
        _ = await say("Did I take my medicine today?")
        _ = await say("I took my Enalapril.")
        _ = await say("Did I take my medicine today?")
        _ = await say("What rules do I have?")
        _ = await say("Delete the milk rule.")
        _ = await say("Yes.")
        log("C rules at end: \(safety.rules.map(\.summary))")
        _ = await say("What did I forget to buy?")
    }
}
#endif
