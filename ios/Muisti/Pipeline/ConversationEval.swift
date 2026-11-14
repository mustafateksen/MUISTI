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

    static func run(controller: CaptureController, folder: String) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        let engine = controller.queryEngine
        let box = LiveBox()
        await engine.setLiveView { box.frame }
        var report: [String] = []
        var passed = 0, total = 0, actionOK = 0
        var prepared: [String: (Data, String)] = [:]

        for (ci, conversation) in conversations.enumerated() {
            await engine.clearConversation()
            for turn in conversation {
                if let file = turn.live {
                    if prepared[file] == nil, let raw = try? Data(contentsOf: dir.appendingPathComponent(file)),
                       let copy = await Task.detached(operation: { SafetyFrame.prepare(raw, maxPixel: 1536) }).value {
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
