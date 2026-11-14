#if DEBUG
import Foundation

/// `--script-only=safetydemo@1`: sample rules, watched states and warnings (frames from
/// `Documents/ingest`) so the Safety page can be checked in the simulator without a model.
@MainActor
enum SafetyDemo {
    static func run(_ safety: SafetyMonitor) async {
        let store = safety.store
        let docs = URL.documentsDirectory.appending(path: "ingest")
        let photos = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var frames: [String] = []
        for url in photos.prefix(6) {
            if let data = try? Data(contentsOf: url), let name = await store.saveFrame(data) { frames.append(name) }
        }
        func frame(_ i: Int) -> String? { frames.indices.contains(i) ? frames[i] : nil }

        let rules = [
            #"{"summary":"Warn me if I leave home with the stove on","watch":["stove"],"trigger":{"type":"context","event":"leaving_home"},"severity":"high","message":"I last saw the stove on."}"#,
            #"{"summary":"Remind me to take my blood pressure pill at 8","watch":["medication:enalapril"],"trigger":{"type":"schedule","time":"08:00"},"severity":"medium","message":"Time for Enalapril."}"#,
            #"{"summary":"Tell me if the front door stays open","watch":["front door"],"trigger":{"type":"inactivity","object":"front door","state":"open","minutes":10},"severity":"low","message":"The door is open.","enabled":false}"#,
        ]
        for json in rules {
            if let rule = try? JSONDecoder().decode(SafetyRule.self, from: Data(json.utf8)) { await store.save(rule) }
        }
        let now = Date()
        // `--safety-demo-quiet`: all warnings already answered (shows the lower half of the page).
        let quiet: SafetyAlert.Response? = ProcessInfo.processInfo.arguments.contains("--safety-demo-quiet") ? .dismissed : nil
        await store.save(ObjectState(object: "stove", state: "on", since: now.addingTimeInterval(-1500), lastSeen: now.addingTimeInterval(-600),
                                     lastStateSeen: now.addingTimeInterval(-600), evidenceFrame: frame(0), place: "kitchen", active: true))
        await store.save(ObjectState(object: "front door", state: "locked", since: now.addingTimeInterval(-4000), lastSeen: now.addingTimeInterval(-3600),
                                     lastStateSeen: now.addingTimeInterval(-3600), evidenceFrame: frame(1), place: "hall"))
        await store.save(ObjectState(object: "medication:enalapril", state: "taken", since: now.addingTimeInterval(-7200), lastSeen: now.addingTimeInterval(-7200),
                                     lastStateSeen: now.addingTimeInterval(-7200), evidenceFrame: nil, source: .user_voice))
        let a1 = await store.insert(SafetyAlert(at: now.addingTimeInterval(-120), ruleID: "demo", message: "You left home. I last saw the stove on at the kitchen, 10 minutes ago.",
                                           evidenceFrame: frame(2), severity: .high, response: quiet))
        let a2 = await store.insert(SafetyAlert(at: now.addingTimeInterval(-60), ruleID: "demo", message: "Time for your Enalapril.", evidenceFrame: nil, severity: .medium, response: quiet.map { _ in .snoozed }))
        let a3 = await store.insert(SafetyAlert(at: now.addingTimeInterval(-86_000), ruleID: "demo", message: "The front door was open for 10 minutes.",
                                           evidenceFrame: frame(3), severity: .low, response: .dismissed))
        // The store keeps answers separately from the insert.
        await store.respond(alert: a3, .dismissed)
        if let quiet {
            await store.respond(alert: a1, quiet)
            await store.respond(alert: a2, .snoozed)
        }
        await safety.reload()
    }
}
#endif
