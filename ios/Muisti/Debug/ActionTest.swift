#if DEBUG
import Foundation

/// Real frames of an action (a hand turning a switch, a key in a lock), a few seconds apart:
/// does the strip look report the action, and does the "did I do it?" check tell a claim the
/// frames show from one they do not. `Documents/actiontest/cases.json`:
/// `[{"name", "frames": [files, oldest first], "seconds", "watched": [objects], "question", "claim",
///    "expect": "shown" | "not_shown", "action": true | false}]`
@MainActor
enum ActionTest {
    struct Case: Decodable {
        let name: String
        let frames: [String]
        let seconds: Int
        let watched: [String]
        let question: String
        let claim: String
        let expect: String
        /// Whether the strip look should report an action on a watched object.
        let action: Bool?
    }

    static func run(controller: CaptureController) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent("actiontest", isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("cases.json")),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else { return }
        var lines: [String] = []
        var passed = 0, total = 0
        for test in cases {
            let jpegs = test.frames.compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
            guard jpegs.count == test.frames.count else {
                lines.append("SKIP \(test.name): frames missing")
                continue
            }
            let masked = await Task.detached { jpegs.compactMap { SafetyFrame.prepare($0, maxPixel: 768, fromPipeline: false)?.jpeg } }.value
            let began = ContinuousClock.now
            let verdict = await QueryEngine.doneVerdict(controller.ai, question: test.question, answer: test.claim, jpegs: masked)
            total += 1
            let ok = verdict?.verdict == test.expect
            if ok { passed += 1 }
            lines.append("\(ok ? "PASS" : "FAIL") done check · \(test.name) · “\(test.claim)” → \(verdict?.verdict ?? "no verdict")"
                         + (verdict?.reply.map { $0.isEmpty ? "" : " · “\($0)”" } ?? "") + " · \((ContinuousClock.now - began).milliseconds) ms")
            if let wanted = test.action {
                let look = await controller.safety.debugStripLook(jpegs, watched: test.watched, seconds: test.seconds)
                let actions = look?.actions.map { "\($0.object):\($0.action)" } ?? []
                let states = look?.objects.filter(\.visible).map { "\($0.name)=\($0.state)" } ?? []
                total += 1
                let seen = !actions.isEmpty
                if seen == wanted { passed += 1 }
                lines.append("\(seen == wanted ? "PASS" : "FAIL") strip look · \(test.name) · actions [\(actions.joined(separator: ", "))] states [\(states.joined(separator: ", "))]")
            }
        }
        lines.insert("ACTIONTEST SUMMARY \(passed)/\(total)", at: 0)
        for line in lines { Log.pipeline.info("\(line, privacy: .public)") }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("action_result.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
