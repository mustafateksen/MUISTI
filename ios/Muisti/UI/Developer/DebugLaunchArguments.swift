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
