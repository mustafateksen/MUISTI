#if DEBUG
import Foundation
import UIKit

/// DEBUG launch arguments for device and simulator testing (see README):
/// `--nemotron-key=…`, `--embed=url|model|key`, `--rerank=model|key`, `--asks=q1||q2`, `--rotate=…`, `--source=…`, `--autostart`, `--mock-autostart`,
/// `--mode=…`, `--script=…`, `--mock-script=…`, `--ask=…`.
@MainActor
enum DebugLaunchArguments {
    static func run(controller: CaptureController, config: AppConfig, wearables: WearablesController) async {
        let args = ProcessInfo.processInfo.arguments
        // `--remote-driver=<port>|<token>`: lets a script or another agent drive the app (see docs/REMOTE_DRIVER.md).
        RemoteDriver.startIfAsked(controller: controller)
        // `--nemotron-key=…`: store a key in the Keychain on a test device (never in code).
        if let key = args.first(where: { $0.hasPrefix("--nemotron-key=") }) {
            config.apiKey = String(key.dropFirst(15))
            await controller.applySettings()
        }
        // `--embed=<https://…/v1>|<model>|<key>`: separate embedding host on a test device.
        if let embed = args.first(where: { $0.hasPrefix("--embed=") }) {
            let parts = embed.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                config.embedBaseURL = parts[0]
                config.embedModel = parts[1]
                config.embedKey = parts[2]
                await controller.applySettings()
            }
        }
        // `--rerank=<model>|<key>`: reranker on a test device (empty model = off).
        if let rerank = args.first(where: { $0.hasPrefix("--rerank=") }) {
            let parts = rerank.dropFirst(9).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            config.rerankModel = parts[0]
            if parts.count > 1 { config.rerankKey = parts[1] }
            await controller.applySettings()
        }
        // `--still=<small|medium|large|full>[|<low|medium|high>]`: photo size on the glasses.
        if let still = args.first(where: { $0.hasPrefix("--still=") }) {
            let parts = still.dropFirst(8).split(separator: "|").map(String.init)
            if let res = parts.first.flatMap(StillResolution.init(rawValue:)) { config.stillResolution = res }
            if parts.count > 1, let q = StillQuality(rawValue: parts[1]) { config.stillQuality = q }
        }
        if let rot = args.first(where: { $0.hasPrefix("--rotate=") }), let deg = Int(rot.dropFirst(9)) {
            config.glassesPhotoRotation = deg
        }
        if let source = args.first(where: { $0.hasPrefix("--source=") }) {
            config.sourceKind = SourceKind(rawValue: String(source.dropFirst(9))) ?? config.sourceKind
        }
        // `--ask-only --asks=q1||q2`: only ask (no capture), e.g. against a device's memory.
        if args.contains("--ask-only") {
            try? await Task.sleep(for: .seconds(3))
            await runScript("asks@0", controller: controller, wearables: wearables)
            return
        }
        // `--script-only=wipe@0,ingest@1,asks@200`: run a script without starting capture.
        if let script = args.first(where: { $0.hasPrefix("--script-only=") }) {
            try? await Task.sleep(for: .seconds(2))
            await runScript(String(script.dropFirst(14)), controller: controller, wearables: wearables)
            return
        }
        // `--autostart`: real glasses, start capturing on launch (device debugging).
        if args.contains("--autostart") {
            if let mode = args.first(where: { $0.hasPrefix("--mode=") }) {
                config.mode = CaptureMode(rawValue: String(mode.dropFirst(7))) ?? config.mode
            }
            try? await Task.sleep(for: .seconds(2))
            await controller.start()
            if let script = args.first(where: { $0.hasPrefix("--script=") }) {
                await runScript(String(script.dropFirst(9)), controller: controller, wearables: wearables)
            }
            return
        }
        // `--mock-autostart`: simulator demo without touching anything.
        guard args.contains("--mock-autostart") else { return }
        let fresh = args.contains("--mock-unregistered")
        controller.mock.quickStart(registered: !fresh, permissionsGranted: !fresh)
        config.sourceKind = .glasses
        if let mode = args.first(where: { $0.hasPrefix("--mode=") }) {
            config.mode = CaptureMode(rawValue: String(mode.dropFirst(7))) ?? config.mode
        }
        try? await Task.sleep(for: .seconds(1))
        await controller.start()
        // `--mock-script=fold@8,unfold@14,doff@22,don@28,tap@34,tap@38`
        if let script = args.first(where: { $0.hasPrefix("--mock-script=") }) {
            await runScript(String(script.dropFirst(14)), controller: controller, wearables: wearables)
        }
    }

    private static func runScript(_ script: String, controller: CaptureController, wearables: WearablesController) async {
        let start = Date()
        let glasses = controller.glasses
        for step in script.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let wait = at - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            Log.mock.info("script: \(String(parts[0]), privacy: .public)")
            switch parts[0] {
            case "fold": controller.mock.setUnfolded(false)
            case "unfold": controller.mock.setUnfolded(true)
            case "doff": controller.mock.setDonned(false)
            case "don": controller.mock.setDonned(true)
            case "tap": controller.mock.tap()
            case "battery5": controller.mock.setBattery(5)
            case "hot": controller.mock.setThermal(.severe)
            case "deny": controller.mock.denyCamera()
            case "background": NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            case "listen": await controller.voice.startListening()
            case "register": await wearables.register()
            case "permit": await glasses.requestPermissionAndStart(using: wearables)
            case "highres": await controller.requestHighRes()
            case "ask": await controller.voice.ask(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ask=") }.map { String($0.dropFirst(6)) } ?? "What did I see?")
            case "asks":
                // `--asks=q1||q2||…`: one question after another (retrieval eval in the simulator).
                let all = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--asks=") }.map { String($0.dropFirst(7)) } ?? ""
                for question in all.components(separatedBy: "||") where !question.isEmpty {
                    await controller.voice.ask(question)
                }
            case "wipe": await controller.deleteAllMemories()
            case "eval":
                // `--eval=<folder in Documents>`: retrieval + answer evaluation (eval.json).
                let folder = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--eval=") }.map { String($0.dropFirst(7)) } ?? "ingest"
                await EvalRunner.run(controller: controller, folder: folder)
            case "conveval":
                // `--conv=<folder in Documents>`: multi-turn conversations, tool use, live view.
                let folder = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--conv=") }.map { String($0.dropFirst(7)) } ?? "conv"
                await ConversationEval.run(controller: controller, folder: folder)
            case "agenteval": await AgentEval.run(controller: controller)
            case "looktest":
                // `--look=<folder in Documents>`: questions about photos given as the live view.
                let folder = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--look=") }.map { String($0.dropFirst(7)) } ?? "looktest"
                await ConversationEval.runLookTest(controller: controller, folder: folder)
            case "privacycheck":
                // Photos in Documents/agentset: `priv_…` must be withheld, the others prepared.
                // Touches no stored data; writes Documents/privacy_result.txt.
                guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { break }
                let files = (try? FileManager.default.contentsOfDirectory(at: documents.appendingPathComponent("agentset"), includingPropertiesForKeys: nil)) ?? []
                var report: [String] = []
                var withheld = 0, privateCount = 0, passed = 0, ordinary = 0
                for file in files.filter({ $0.pathExtension == "jpg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard let raw = try? Data(contentsOf: file), let image = ImageData.thumbnail(raw, maxPixel: 1280) else { continue }
                    let isPrivate = PerceptionEngine.showsPrivateScene(image)
                    let prepared = SafetyFrame.prepare(raw, maxPixel: 1280, fromPipeline: false) != nil
                    if file.lastPathComponent.hasPrefix("priv_") { privateCount += 1; if isPrivate, !prepared { withheld += 1 } }
                    else { ordinary += 1; if !isPrivate, prepared { passed += 1 } }
                    report.append("\(file.lastPathComponent): private \(isPrivate), prepared \(prepared)")
                }
                report.insert("PRIVACY withheld \(withheld)/\(privateCount) · ordinary through \(passed)/\(ordinary)", at: 0)
                try? report.joined(separator: "\n").write(to: documents.appendingPathComponent("privacy_result.txt"), atomically: true, encoding: .utf8)
            case "agentseed":
                // A few notes and log entries, for looking at the assistant notes screen.
                let agent = controller.agent
                await agent.deleteAll()
                agent.policy.speak = { _, _, _, _, _ in }
                agent.policy.notify = { _, _, _ in }
                _ = await agent.handle(.remember(text: "Buy milk", say: "You wanted to buy milk.", kind: .todo, cue: Cue(place: "grocery store", sight: "a grocery store with milk on the shelves")))
                _ = await agent.handle(.remember(text: "Call the dentist", say: "You wanted to call the dentist.", kind: .reminder, cue: Cue(at: Cue.stamp(Date().addingTimeInterval(18 * 3600)))))
                _ = await agent.handle(.rememberFact("The user's car is a blue Toyota."))
                await agent.policy.submit(Proposal(topic: "reminder", urgency: .timely, text: "You wanted to pick up your prescription — there's a CVS pharmacy right here."))
                await agent.policy.submit(Proposal(topic: "notice", urgency: .fyi, text: "A no-smoking sign in a subway station."))
            case "safetydemo": await SafetyDemo.run(controller.safety)
            case "safetyeval":
                // `--safety=<folder in Documents>`: Muisti Turva scenarios, photos, conversation.
                let folder = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--safety=") }.map { String($0.dropFirst(9)) } ?? "safety"
                await SafetyEval.run(controller: controller, folder: folder)
            case "waitidle":
                // Wait until every frame is structured, embedded and every episode summarised.
                for _ in 0..<600 {
                    let counts = await controller.store.count()
                    let imagesOn = await controller.ai.imageEmbeddingsEnabled
                    let imagesLeft = await controller.store.missingImageEmbeddings(limit: 1).isEmpty == false
                    if counts.pending == 0, await controller.store.missingEmbeddings(limit: 1).isEmpty,
                       !(imagesOn && imagesLeft),
                       await controller.store.episodeNeedingSummary(settle: 0) == nil { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                Log.mock.info("idle: all frames processed")
            case "ingest":
                // `--ingest=<folder in Documents>`: test photos through the real pipeline.
                let folder = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ingest=") }.map { String($0.dropFirst(9)) } ?? "ingest"
                let kept = await controller.ingestFolder(folder)
                Log.mock.info("ingest done: \(kept) kept")
            case "capture": await controller.captureNow()
            case "stop": await controller.stop()
            case "start": await controller.start()
            default: break
            }
        }
    }
}
#endif
