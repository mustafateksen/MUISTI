#if DEBUG
import Foundation

/// Conversation evaluation on the simulator (DEBUG only): multi-turn chats through the real
/// answer engine, checking for each turn what the model did (looked through the glasses,
/// chatted, answered from memory) and what it said. The live view is a test photo from
/// `Documents/<folder>/` instead of the glasses. Writes `conv_result.txt` and `CONV` log lines.
@MainActor
enum ConversationEval {
    enum Expect: String { case look, chat, memory }

    struct Turn {
        let say: String
        let expect: Expect
        var live: String? = nil
        var must: [String] = []
        var mustNot: [String] = []
    }

    static let conversations: [[Turn]] = [
        [
            Turn(say: "What's up?", expect: .chat),
            Turn(say: "Check by yourself, looking at my view", expect: .look, live: "d051.jpg", must: ["bicycle", "bike", "parkir", "basikal"]),
            Turn(say: "What does the sign say exactly?", expect: .look, live: "d051.jpg", must: ["parkir", "basikal", "bicycle"]),
            Turn(say: "OK that's good", expect: .chat),
        ],
        [
            Turn(say: "Define what you see", expect: .look, live: "tv_trap.jpg", must: ["tv", "television", "screen", "cooking"]),
            Turn(say: "Is the stove on?", expect: .look, live: "tv_trap.jpg", must: ["tv", "television", "screen", "show"]),
        ],
        [
            Turn(say: "Read this for me", expect: .look, live: "ingredients_label_4.jpg", must: ["sea urchin", "fish", "farina"]),
            Turn(say: "Does it contain milk?", expect: .look, live: "ingredients_label_4.jpg", must: ["no", "not", "doesn"]),
        ],
        [
            // Garbled: looking, or offering to look, are both right; "yes" must then look.
            Turn(say: "See what I'm saying", expect: .look, live: "d023.jpg", must: ["slow", "keep left", "shared", "look"]),
            Turn(say: "Yes, look", expect: .look, live: "d023.jpg", must: ["slow", "keep left", "shared"]),
        ],
        [
            Turn(say: "Which pharmacy was open 24 hours?", expect: .memory, must: ["cvs"]),
            Turn(say: "What did I see right after it?", expect: .memory, must: ["rite aid", "gorham"]),
            Turn(say: "Thanks!", expect: .chat),
        ],
        [
            Turn(say: "What am I looking at right now?", expect: .look, live: "gas_stove_flame_0.jpg", must: ["flame", "burner", "stove", "gas"]),
            Turn(say: "Is it on?", expect: .look, live: "gas_stove_flame_0.jpg", must: ["yes", "on", "lit", "flame"]),
        ],
        [
            Turn(say: "What is an Arduino?", expect: .chat, must: ["board", "microcontroller", "electronic"]),
        ],
        [
            Turn(say: "What was the phone number of the Old World food truck?", expect: .memory, must: ["415"]),
            Turn(say: "And where was it?", expect: .memory, must: ["messuaukio"]),
        ],
        [
            Turn(say: "Şu an ne görüyorsun?", expect: .look, live: "d051.jpg", must: ["bisiklet", "parkir", "bicycle", "park"]),
        ],
        [
            Turn(say: "naber", expect: .chat),
            Turn(say: "iyiyim, sen?", expect: .chat),
        ],
        [
            Turn(say: "What color is this sign?", expect: .look, live: "d051.jpg", must: ["blue"]),
        ],
        [
            Turn(say: "Look at this and tell me what it is", expect: .look, live: "gas_stove_flame_0.jpg", must: ["flame", "stove", "burner", "gas"]),
            Turn(say: "What was the phone number of the Old World food truck?", expect: .memory, live: "gas_stove_flame_0.jpg", must: ["415"]),
        ],
        [
            Turn(say: "Is there anything dangerous in front of me?", expect: .look, live: "gas_stove_flame_0.jpg", must: ["flame", "stove", "burner", "gas", "fire"]),
        ],
        [
            Turn(say: "Bu tabelada ne yazıyor?", expect: .look, live: "d023.jpg", must: ["slow", "keep left", "yavaş", "sol"]),
            Turn(say: "Peki bu ne demek?", expect: .look, live: "d023.jpg", must: ["yavaş", "sol", "paylaş", "ortak", "slow"]),
        ],
        [
            Turn(say: "Where was the hair dressing parlor?", expect: .memory, must: ["state street", "322", "fleminginkatu"]),
            Turn(say: "What's in front of me now?", expect: .look, live: "keys_on_kitchen_table_0.jpg", must: ["table", "chair", "chandelier", "room"]),
        ],
    ]

    final class LiveBox: @unchecked Sendable {
        var frame: (jpeg: Data, ocr: String, at: Date)?
    }

    /// "Can it do this with what I am looking at?": each entry of `Documents/<folder>/tests.json`
    /// (`file`, `say`, `must`) is asked as a fresh conversation with that photo as the live
    /// view. Writes `look_result.txt` and `LOOKTEST` log lines.
    /// The long-conversation test of pipeline v2: 30 turns, things said early asked for late
    /// (by then they are only in a summary), and the same after a restart (a new engine that
    /// has nothing but the dialog on disk). Writes `Documents/dialog_result.txt`.
    static func runDialogTest(controller: CaptureController) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let engine = controller.queryEngine
        await engine.resetConversation()
        let filler = ["What is an Arduino?", "Thanks.", "How many minutes are in a day?", "OK, good.", "What is the capital of Finland?",
                      "Nice.", "What does HTTP stand for?", "Got it.", "How far is the Moon?", "Great, thanks.", "What is a haiku?",
                      "Alright.", "Who wrote Kalevala?", "Thank you.", "What is the boiling point of water?", "OK.",
                      "What is a prime number?", "Cool.", "How many legs does a spider have?", "Thanks a lot.", "What is photosynthesis?",
                      "I see.", "What is the tallest mountain on Earth?", "OK thanks.", "What is an API?", "Good to know."]
        // turn number (1-based) → what is said; the rest is filler.
        let said: [Int: String] = [3: "By the way, my sister Leena lands tonight at 18:40, on flight AY1337.",
                                   12: "I'm meeting Jussi from Wolt at the coffee place called Fazer on Kluuvikatu tomorrow at ten.",
                                   25: "What time does my sister land?", 27: "And what was her flight number?",
                                   29: "Who am I meeting tomorrow, and where?"]
        let must: [Int: [String]] = [25: ["18:40"], 27: ["1337"], 29: ["jussi", "fazer"]]
        var lines: [String] = []
        var passed = 0, total = 0
        var next = 0
        for turn in 1...30 {
            let text = said[turn] ?? filler[next % filler.count]
            if said[turn] == nil { next += 1 }
            let result = await engine.ask(text, location: nil)
            await ContextBuilder.summarizeIfNeeded(engine.dialog, ai: controller.ai)
            if let needed = must[turn] {
                total += 1
                let answer = result.answer.lowercased()
                let ok = needed.allSatisfy { answer.contains($0) }
                if ok { passed += 1 }
                lines.append("\(ok ? "PASS" : "FAIL") turn \(turn) “\(text)” → \(result.answer) · \(result.latencyMs) ms · \(result.trace ?? "")")
            }
        }
        let summaries = await engine.dialog.summaries(since: Date().addingTimeInterval(-3600))
        lines.append("summaries made: \(summaries.count)" + summaries.map { "\n  · \($0.text)" }.joined())
        // Restart: a new engine, nothing in memory but the same dialog file.
        let restarted = QueryEngine(store: controller.store, ai: controller.ai)
        for (question, needed) in [("What did I tell you about my sister today?", ["18:40"]), ("Remind me, who was I going to meet tomorrow?", ["jussi"])] {
            let result = await restarted.ask(question, location: nil)
            total += 1
            let answer = result.answer.lowercased()
            let ok = needed.contains { answer.contains($0) }
            if ok { passed += 1 }
            lines.append("\(ok ? "PASS" : "FAIL") after restart “\(question)” → \(result.answer) · \(result.latencyMs) ms · \(result.trace ?? "")")
        }
        lines.insert("DIALOGTEST SUMMARY \(passed)/\(total)", at: 0)
        for line in lines { Log.pipeline.info("\(line, privacy: .public)") }
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("dialog_result.txt"), atomically: true, encoding: .utf8)
        await engine.resetConversation()
    }

    /// Peak load (pipeline v2, §8): 64 frame analyses with pictures are sent at once on the
    /// background lane while turn decisions are made on the user lane; what counts is how long
    /// the user's calls take meanwhile. Writes `Documents/load_result.txt`.
    static func runLoadTest(controller: CaptureController) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let ai = controller.ai
        let store = controller.store
        let frames = await store.recent(limit: 8).compactMap { record in (try? Data(contentsOf: store.frameURL(record))).map { (record.ocrText, $0) } }
        guard !frames.isEmpty else { return }
        func decide(_ question: String) async -> Int? {
            await ai.beginQuestion()
            defer { Task { await ai.endQuestion() } }
            let began = ContinuousClock.now
            let reply = try? await ai.chatTools(system: TurnTools.system,
                                                user: TurnTools.user(question: question, now: Date(), conversation: [], safety: "", lookedSecondsAgo: nil),
                                                tools: TurnTools.tools)
            return reply == nil ? nil : (ContinuousClock.now - began).milliseconds
        }
        let questions = ["What was the phone number of the food truck?", "Where did I see a pharmacy?", "What is this?", "Thanks!",
                         "Remind me to buy milk", "Did I see a church?", "What time is it in Tokyo?", "Where were the toilets?",
                         "Read this for me", "What did I see most recently?", "Is the stove on?", "Which bakeries did I pass?"]
        var quiet: [Int] = []
        for q in questions.prefix(6) { if let ms = await decide(q) { quiet.append(ms) } }
        let began = ContinuousClock.now
        let background = Task { () -> (done: Int, failed: Int, ms: Int) in
            await withTaskGroup(of: Bool.self) { group in
                for i in 0..<64 {
                    let (ocr, jpeg) = frames[i % frames.count]
                    group.addTask {
                        (try? await ai.chat(system: MemoryPrompts.extractionSystem, user: MemoryPrompts.extractionUser(ocr: ocr),
                                            image: .init(jpeg: jpeg), jsonSchema: MemoryPrompts.extractionSchema, schemaName: "memory_record",
                                            maxTokens: 2500, temperature: 0, background: true)) != nil
                    }
                }
                var done = 0, failed = 0
                for await ok in group { if ok { done += 1 } else { failed += 1 } }
                return (done, failed, (ContinuousClock.now - began).milliseconds)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        var busy: [Int] = []
        var round = 0
        while !background.isCancelled, round < 4 {
            round += 1
            await withTaskGroup(of: Int?.self) { group in
                for q in questions.prefix(4) { group.addTask { await decide(q) } }
                for await ms in group { if let ms { busy.append(ms) } }
            }
        }
        let result = await background.value
        func pct(_ v: [Int], _ p: Double) -> Int { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }
        let lines = ["LOADTEST SUMMARY user-lane turn decision: quiet p50 \(pct(quiet, 0.5)) ms p90 \(pct(quiet, 0.9)) ms · under load p50 \(pct(busy, 0.5)) ms p90 \(pct(busy, 0.9)) ms (\(busy.count) calls, 4 at a time)",
                     "background: 64 frame analyses with pictures sent at once (lane lets 8 through, 2 while a question is answered): \(result.done) done, \(result.failed) failed in \(result.ms) ms"]
        for line in lines { Log.pipeline.info("\(line, privacy: .public)") }
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("load_result.txt"), atomically: true, encoding: .utf8)
    }

    static func runLookTest(controller: CaptureController, folder: String) async {
        struct Case: Decodable { let file: String; let say: String; let must: [String]; var any: [String]?; var not: [String]? }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("tests.json")),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else { return }
        let engine = controller.queryEngine
        let box = LiveBox()
        await engine.setLiveView { box.frame }
        await engine.setCameraLive { box.frame != nil }
        var lines: [String] = []
        var passed = 0
        for test in cases {
            await engine.resetConversation()
            guard let raw = try? Data(contentsOf: dir.appendingPathComponent(test.file)),
                  let copy = await Task.detached(operation: { SafetyFrame.prepare(raw, maxPixel: 1536, fromPipeline: false) }).value else {
                lines.append("SKIP \(test.file): could not be prepared")
                continue
            }
            box.frame = (copy.jpeg, copy.ocr, Date())
            let result = await engine.ask(test.say, location: nil)
            let answer = result.answer.lowercased()
            // must: all of them; any: at least one; not: none of them.
            let ok = test.must.allSatisfy { answer.contains($0.lowercased()) }
                && (test.any.map { $0.contains { answer.contains($0.lowercased()) } } ?? true)
                && !(test.not ?? []).contains { answer.contains($0.lowercased()) }
            if ok { passed += 1 }
            let line = "\(ok ? "PASS" : "FAIL") \(test.file) “\(test.say)” → [\(result.label.rawValue)] \(result.answer) · \(result.latencyMs) ms · \(result.trace ?? "")"
            lines.append(line)
            Log.pipeline.info("LOOKTEST \(line, privacy: .public)")
        }
        lines.insert("LOOKTEST SUMMARY \(passed)/\(cases.count)", at: 0)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("look_result.txt"), atomically: true, encoding: .utf8)
    }

    static func run(controller: CaptureController, folder: String) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        let engine = controller.queryEngine
        let box = LiveBox()
        await engine.setLiveView { box.frame }
        await engine.setCameraLive { box.frame != nil }
        var report: [String] = []
        var passed = 0, total = 0, actionOK = 0
        var prepared: [String: (Data, String)] = [:]

        for (ci, conversation) in conversations.enumerated() {
            await engine.resetConversation()
            for turn in conversation {
                if let file = turn.live {
                    if prepared[file] == nil, let raw = try? Data(contentsOf: dir.appendingPathComponent(file)),
                       let copy = await Task.detached(operation: { SafetyFrame.prepare(raw, maxPixel: 1536, fromPipeline: false) }).value {
                        prepared[file] = (copy.jpeg, copy.ocr)
                    }
                    box.frame = prepared[file].map { ($0.0, $0.1, Date()) }
                } else {
                    box.frame = nil
                }
                let result = await engine.ask(turn.say, location: nil)
                let trace = result.trace ?? ""
                // The model's own action first; a carried live frame counts as looking.
                // look_now = looked; a carried live frame counts as looking unless the answer
                // cites memory records.
                let did: Expect = trace.contains("look_now") ? .look
                    : (trace.contains("· chat") || trace.hasSuffix("chat") || trace.contains("→ chat") ? .chat
                       : (trace.contains("live view") && result.liveFrame != nil && result.evidence.isEmpty ? .look : .memory))
                let answer = EvalRunner.normalize(result.answer)
                let offeredLook = turn.expect == .look && did == .chat && answer.contains("look")
                let actionPass = (did == turn.expect || offeredLook) && (turn.expect != .memory || result.label == .seen)
                let mustPass = turn.must.isEmpty || turn.must.contains { answer.contains(EvalRunner.normalize($0)) }
                let mustNotPass = !turn.mustNot.contains { answer.contains(EvalRunner.normalize($0)) }
                let pass = actionPass && mustPass && mustNotPass
                total += 1
                if pass { passed += 1 }
                if actionPass { actionOK += 1 }
                Log.pipeline.info("CONV TRACE c\(ci + 1) \(trace, privacy: .public)")
                let line = "CONV \(pass ? "PASS" : "FAIL") c\(ci + 1) “\(turn.say)” want \(turn.expect.rawValue) did \(did.rawValue) [\(result.label.rawValue)]\(result.expectsReply ? " [asks back]" : "") → \(result.answer) · \(result.latencyMs) ms"
                report.append(line)
                Log.pipeline.info("\(line, privacy: .public)")
            }
        }
        let summary = "CONV SUMMARY \(passed)/\(total) pass · actions \(actionOK)/\(total)"
        report.append(summary)
        Log.pipeline.info("\(summary, privacy: .public)")
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("conv_result.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
