#if DEBUG
import AVFoundation
import CoreLocation
import Foundation
import Network
import UIKit

/// A door for driving the app from outside, in DEBUG builds only: another program (a script, a
/// coding agent on a Mac) shows Muisti a recorded video or photos as if the glasses saw them,
/// talks to it like a user, and reads back what it answered and what it brought up by itself.
/// For preparing demos and for testing whole days without wearing the glasses.
///
/// Off unless the app is launched with `--remote-driver=<port>|<token>`; every request must
/// carry the token. The driver only carries things in and out: frames go through the same
/// perception, memory, safety and agent code as frames from the glasses, questions through the
/// same turn as typed questions. The spoken path (microphone, speech recognition, the glasses'
/// speaker) is not part of it.
@MainActor
final class RemoteDriver {
    static var shared: RemoteDriver?

    private let controller: CaptureController
    private let token: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fi.junction.muisti.remote-driver")
    private var videoTask: Task<Void, Never>?
    private var video = VideoProgress()
    private var live: (jpeg: Data, ocr: String, at: Date)?
    private let liveBox = LiveBox()

    struct VideoProgress { var file = ""; var planned = 0; var fed = 0; var kept = 0; var running = false }
    final class LiveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (jpeg: Data, ocr: String, at: Date)?
        func set(_ new: (jpeg: Data, ocr: String, at: Date)?) { lock.lock(); value = new; lock.unlock() }
        func get() -> (jpeg: Data, ocr: String, at: Date)? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Posted with the screen's name; `RootView` switches to it.
    static let showScreen = Notification.Name("muisti.remoteDriver.showScreen")
    static let defaultPort: UInt16 = 8765
    /// Pictures uploaded for the staged demo.
    static let stageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("muisti-stage", isDirectory: true)
    private(set) static var port: UInt16 = defaultPort
    private(set) static var failure: String?

    /// Switched on in the app (Developer › Remote driver): remembered across launches.
    static var enabledInApp: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteDriver.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "remoteDriver.enabled") }
    }

    /// The token for a driver switched on in the app: made once on this phone, shown on screen.
    static var appToken: String {
        if let saved = UserDefaults.standard.string(forKey: "remoteDriver.token"), saved.count >= 8 { return saved }
        let made = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        UserDefaults.standard.set(String(made), forKey: "remoteDriver.token")
        return String(made)
    }

    /// At launch: `--remote-driver=<port>|<token>` (`--remote-driver-speak` keeps Muisti's voice
    /// on), or the switch in the app from last time.
    static func startIfAsked(controller: CaptureController) {
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--remote-driver=") }) {
            let parts = arg.dropFirst("--remote-driver=".count).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let port = UInt16(parts[0]), parts[1].count >= 8 else {
                Log.app.error("remote driver: needs --remote-driver=<port>|<token of 8+ characters>")
                return
            }
            // `--remote-driver-keep`: stays on with this token when the app is opened by hand
            // later (a phone handed to someone without Xcode), on the default port.
            if ProcessInfo.processInfo.arguments.contains("--remote-driver-keep") {
                UserDefaults.standard.set(parts[1], forKey: "remoteDriver.token")
                enabledInApp = true
            }
            start(controller: controller, port: port, token: parts[1], speak: ProcessInfo.processInfo.arguments.contains("--remote-driver-speak"))
        } else if enabledInApp {
            start(controller: controller, port: defaultPort, token: appToken, speak: false)
        }
    }

    @discardableResult
    static func start(controller: CaptureController, port: UInt16, token: String, speak: Bool) -> Bool {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: .tcp, on: nwPort) else {
            failure = "Port \(port) could not be opened."
            return false
        }
        failure = nil
        // The screen may be recorded: no timings or traces under the answers.
        UserDefaults.standard.set(true, forKey: DeveloperMode.cleanScreenKey)
        Self.port = port
        let driver = RemoteDriver(controller: controller, token: token, listener: listener)
        shared = driver
        driver.start(speak: speak)
        // The phone must stay awake and in front: a suspended app answers nothing.
        UIApplication.shared.isIdleTimerDisabled = true
        Log.app.info("remote driver listening on port \(port)")
        return true
    }

    static func stop() {
        UserDefaults.standard.set(false, forKey: DeveloperMode.cleanScreenKey)
        UserDefaults.standard.removeObject(forKey: DeveloperMode.stageStatusKey)
        shared?.listener.cancel()
        shared?.videoTask?.cancel()
        shared = nil
    }

    /// This phone's address on the Wi-Fi network, for the screen that shows where to connect.
    static var wifiAddress: String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var found: String?
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
            }
        }
        return found
    }

    private init(controller: CaptureController, token: String, listener: NWListener) {
        self.controller = controller
        self.token = token
        self.listener = listener
    }

    private func start(speak: Bool) {
        if !speak {
            // What Muisti would say aloud is read from /ask and /events instead.
            controller.voice.speakAnswers = false
            let engine = controller.queryEngine
            controller.agent.policy.speak = { text, _, _, _, _ in await engine.noteMuistiSaid(text) }
            controller.agent.policy.chime = {}
        }
        // "What is this?" looks at the newest frame the driver showed.
        let box = liveBox
        let engine = controller.queryEngine
        Task {
            await engine.setLiveView { box.get() }
            await engine.setCameraLive { box.get() != nil }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            Self.receive(connection, buffer: Data()) { request in
                Task { @MainActor in
                    let response = await self?.handle(request) ?? Response(status: 503, json: ["error": "driver gone"])
                    Self.send(response, on: connection)
                }
            }
        }
        listener.start(queue: queue)
    }

    // MARK: HTTP (just enough of it)

    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var json: [String: Any]
        /// A file instead of JSON (an evidence frame).
        var data: Data?
        var contentType = "application/json; charset=utf-8"

        init(status: Int, json: [String: Any]) { self.status = status; self.json = json }
        init(jpeg: Data) { status = 200; json = [:]; data = jpeg; contentType = "image/jpeg" }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data, _ done: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                done(request)
            } else if isComplete || error != nil || buffer.count > 600_000_000 {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer, done)
            }
        }
    }

    /// A whole request, once the headers and `Content-Length` bytes of body have arrived.
    private nonisolated static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(first[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first[0]), path: components?.path ?? target, query: query, headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private nonisolated static func send(_ response: Response, on connection: NWConnection) {
        let body = response.data ?? (try? JSONSerialization.data(withJSONObject: response.json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = response.status == 200 ? "OK" : "Error"
        var out = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Routes

    private func handle(_ request: Request) async -> Response {
        let given = request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "") ?? request.headers["x-muisti-token"] ?? ""
        guard given == token else { return Response(status: 401, json: ["error": "missing or wrong token"]) }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { body[key] ?? request.query[key] }
        func number(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue ?? (value(key) as? String).flatMap(Double.init) }
        func text(_ key: String) -> String? { value(key) as? String }

        switch (request.method, request.path) {
        case ("GET", "/state"): return Response(status: 200, json: await state())
        case ("GET", "/events"): return Response(status: 200, json: await events(since: Int64(request.query["since"] ?? "") ?? 0))
        case ("GET", "/evidence"):
            // The stored (blurred) frame of a memory record, as a JPEG.
            guard let id = Int64(request.query["id"] ?? ""), let record = await controller.store.record(id: id),
                  let jpeg = try? Data(contentsOf: controller.store.frameURL(record)) else { return Response(status: 404, json: ["error": "no such record"]) }
            return Response(jpeg: jpeg)
        case ("GET", "/wait-idle"): return Response(status: 200, json: await waitIdle(seconds: Double(request.query["timeout"] ?? "") ?? 180))
        case ("POST", "/ask"):
            guard let question = text("text"), !question.isEmpty else { return Response(status: 400, json: ["error": "text is missing"]) }
            return Response(status: 200, json: await ask(question))
        case ("POST", "/frame"):
            let isImage = request.headers["content-type"]?.hasPrefix("image/") == true
            guard let raw = isImage ? request.body : text("path").flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }),
                  let jpeg = ImageData.ensureJPEG(raw) else { return Response(status: 400, json: ["error": "send a JPEG body (Content-Type: image/jpeg) or {\"path\": …}"]) }
            return Response(status: 200, json: await show(jpeg, at: Date(), store: request.query["store"] != "0" && (value("store") as? Bool) != false))
        case ("POST", "/video"):
            var path = text("path")
            if request.headers["content-type"]?.hasPrefix("video/") == true {
                let ending = request.headers["content-type"]?.contains("quicktime") == true ? "mov" : "mp4"
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("driver-\(UUID().uuidString).\(ending)")
                try? request.body.write(to: file)
                path = file.path
            }
            guard let path, FileManager.default.fileExists(atPath: path) else { return Response(status: 400, json: ["error": "no video at that path (send {\"path\": …} or the file as a video/mp4 body)"]) }
            // The track comes in the JSON body, or (with an uploaded file) as JSON in the query.
            let trackJSON = body["track"] as? [[String: Any]]
                ?? (request.query["track"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]) ?? []
            let track = trackJSON.compactMap { point -> (t: Double, lat: Double, lon: Double)? in
                guard let t = (point["t"] as? NSNumber)?.doubleValue, let lat = (point["lat"] as? NSNumber)?.doubleValue,
                      let lon = (point["lon"] as? NSNumber)?.doubleValue else { return nil }
                return (t, lat, lon)
            }
            return Response(status: 200, json: await play(path: path, step: max(0.2, number("step") ?? 1), speed: max(0, number("speed") ?? 4),
                                                           track: track, motion: text("motion")))
        case ("POST", "/location"):
            guard let lat = number("lat"), let lon = number("lon") else { return Response(status: 400, json: ["error": "lat and lon are needed"]) }
            controller.location.inject(CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 0, horizontalAccuracy: number("accuracy") ?? 8,
                                                  verticalAccuracy: 8, course: number("course") ?? -1, speed: number("speed") ?? 1.3, timestamp: Date()))
            await controller.agent.navigationFix(controller.location.latest!)
            await controller.agent.tick()
            return Response(status: 200, json: ["position": controller.location.positionText() ?? "unknown"])
        case ("POST", "/motion"):
            guard let kind = text("kind").flatMap(MotionActivityKind.init(rawValue:)) else {
                return Response(status: 400, json: ["error": "kind: stationary, walking, running, cycling or automotive"])
            }
            controller.motion.simulate(kind)
            await controller.agent.tick()
            return Response(status: 200, json: ["motion": kind.rawValue])
        case ("POST", "/tick"):
            await controller.agent.tick()
            // `review`: Muisti's own look at the day right now, whatever its usual pace.
            if value("review") as? Bool == true { await controller.agent.review(now: Date(), forced: true) }
            return Response(status: 200, json: ["ok": true])
        case ("POST", "/reply"):
            let command: SafetyCommand
            switch text("answer") {
            case "yes": command = .confirm
            case "no": command = .cancel
            case "not_now": command = .snooze
            default: return Response(status: 400, json: ["error": "answer: yes, no or not_now"])
            }
            let reply = await controller.voice.safetyHandler(command)
            return Response(status: 200, json: ["reply": orNull(reply)])
        case ("GET", "/chat"):
            // The conversation as the Ask tab shows it, oldest first (Muisti's own remarks included).
            return Response(status: 200, json: ["turns": controller.voice.history.reversed().map { turn -> [String: Any] in
                ["question": turn.question, "answer": turn.answer, "label": turn.label.rawValue, "by_muisti": turn.spontaneous,
                 "evidence": turn.evidence.map(\.record.id)]
            }])
        case ("GET", "/memories"):
            let records = await controller.store.recent(limit: min(200, Int(request.query["limit"] ?? "") ?? 30))
            let stamp = ISO8601DateFormatter()
            return Response(status: 200, json: ["memories": records.map { r -> [String: Any] in
                ["id": r.id, "title": r.title, "seen_at": stamp.string(from: r.seenAt), "street": orNull(r.street), "area": orNull(r.area),
                 "text": String(r.ocrText.prefix(400)), "caption": orNull(r.caption), "status": "\(r.status)"]
            }])
        case ("POST", "/memory/delete"):
            guard let id = number("id") else { return Response(status: 400, json: ["error": "id is needed"]) }
            await controller.deleteMemory(Int64(id))
            return Response(status: 200, json: ["deleted": Int64(id)])
        case ("POST", "/forget"):
            guard let minutes = number("minutes"), minutes >= 1 else { return Response(status: 400, json: ["error": "minutes is needed"]) }
            await controller.forget(minutes: Int(minutes))
            return Response(status: 200, json: ["forgot_minutes": Int(minutes)])
        case ("POST", "/chat/clear"):
            controller.voice.clearConversation()
            return Response(status: 200, json: ["cleared": true])
        case ("POST", "/intent"):
            // What the notes screen offers: mark done, or remove.
            await controller.agent.reload()
            guard let id = text("id"), let intent = controller.agent.intents.first(where: { $0.id == id }) else { return Response(status: 404, json: ["error": "no such open intent"]) }
            if text("action") == "done" { await controller.agent.markDone(intent) } else { await controller.agent.remove(intent) }
            return Response(status: 200, json: ["id": id, "action": text("action") == "done" ? "done" : "removed"])
        case ("POST", "/rule"):
            // What the Safety tab offers: switch a rule on or off, or delete it.
            guard let id = text("id"), let rule = controller.safety.rules.first(where: { $0.id == id }) else { return Response(status: 404, json: ["error": "no such rule"]) }
            if text("action") == "delete" { await controller.safety.delete(rule) }
            else { await controller.safety.setEnabled(rule, text("action") != "off") }
            return Response(status: 200, json: ["id": id, "action": text("action") ?? "on"])
        case ("POST", "/settings"):
            // The switches of Settings › Assistant, plus whether answers are read aloud.
            let settings = controller.agent.settings
            func flag(_ key: String) -> Bool? { value(key) as? Bool ?? (value(key) as? String).map { $0 == "true" || $0 == "1" || $0 == "on" } }
            if let v = flag("assistant") { settings.enabled = v }
            if let v = flag("noticing") { settings.noticing = v }
            if let v = flag("navigation") { settings.navigation = v }
            if let v = flag("people") { settings.people = v }
            if let v = flag("map_search") { settings.mapSearch = v }
            if let v = flag("evening_summary") { settings.eveningDigest = v }
            if let v = number("spoken_per_day") { settings.dailySpokenBudget = Int(v) }
            if let v = number("minutes_apart") { settings.minGapMinutes = Int(v) }
            if let v = number("quiet_from") { settings.quietFromHour = Int(v) }
            if let v = number("quiet_to") { settings.quietToHour = Int(v) }
            if let v = flag("safety_auto") { controller.config.safetyAuto = v }
            if let v = number("private_pause") {
                PerceptionEngine.privatePause = max(0, v)
                PerceptionEngine.endPrivatePause()
            }
            return Response(status: 200, json: ["assistant": settings.enabled, "noticing": settings.noticing, "navigation": settings.navigation,
                                                "people": settings.people, "map_search": settings.mapSearch, "evening_summary": settings.eveningDigest,
                                                "spoken_per_day": settings.dailySpokenBudget, "minutes_apart": settings.minGapMinutes,
                                                "quiet_from": settings.quietFromHour, "quiet_to": settings.quietToHour, "safety_auto": controller.config.safetyAuto,
                                                "private_pause": PerceptionEngine.privatePause])
        case ("POST", "/log"):
            // An entry in Muisti Turva's log at a given time: earlier days for the habits demo.
            guard let object = text("object"), let value = text("value") else {
                return Response(status: 400, json: ["error": "object and value are needed; at: yyyy-MM-dd HH:mm (default now); kind: action or state"])
            }
            let at = text("at").flatMap { Cue(at: $0).nextDue(after: Date()) } ?? Date()
            let kind: SafetyEventKind = text("kind") == "state" ? .state : .action
            let id = await controller.safety.store.insert(SafetyEvent(at: at, kind: kind, object: object.lowercased(), value: value.lowercased(),
                                                                      confidence: nil, source: .user_confirmed, frameFile: nil))
            return Response(status: 200, json: ["id": Int(id), "at": Cue.stamp(at)])
        case ("POST", "/speech"):
            // A recording (WAV or any audio file as the body) through every on-device speech
            // engine, and what the two "is someone speaking" detectors make of it.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("driver-speech-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? request.body.write(to: file)) != nil, let audio = try? AVAudioFile(forReading: file),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil else {
                return Response(status: 400, json: ["error": "send an audio file as the body"])
            }
            let samples = Resampler16k().convert(buffer)
            let locale = text("locale") ?? controller.voice.localeIdentifier
            var out: [String: Any] = ["seconds": Double(samples.count) / 16_000, "locale": locale]
            func timed(_ name: String, _ run: () async -> String?) async {
                let began = Date()
                let heard = await run()
                out[name] = ["text": heard as Any? ?? NSNull(), "seconds": Date().timeIntervalSince(began)] as [String: Any]
            }
            await SpeechLab.shared.prepareEndpoint()
            await timed("parakeet") {
                guard await SpeechLab.shared.prepareParakeet(locale) else { return nil }
                return await SpeechLab.shared.transcribe(samples, localeIdentifier: locale)
            }
            await timed("apple_general") { await AppleSpeechTest.modern(samples, localeIdentifier: locale, dictation: false) }
            await timed("apple_dictation") { await AppleSpeechTest.modern(samples, localeIdentifier: locale, dictation: true) }
            await timed("apple_legacy") { await AppleSpeechTest.legacy(samples, localeIdentifier: locale) }
            // Per 256 ms: the speech model's verdict and the loudness detector's.
            let trace = await SpeechLab.shared.speechTrace(samples)
            let loudness = VoiceActivity()
            var loud: [Bool] = []
            var index = 0
            while index + 4096 <= samples.count {
                loud.append(Resampler16k.buffer(Array(samples[index..<(index + 4096)])).map { loudness.isVoice($0) } ?? false)
                index += 4096
            }
            // The same verdict a live session uses: speech, and loud enough to be the user.
            var judge = VoiceGate.Judge()
            let mine = trace.enumerated().map { hop, probability -> Bool in
                let from = hop * 4096
                return judge.isUser(probability: probability, samples: Array(samples[min(from, samples.count)..<min(from + 4096, samples.count)]))
            }
            let lastSpeech = mine.lastIndex(of: true)
            // What a live session would hand to Parakeet: up to half a second past the user's speech.
            if let lastSpeech, (lastSpeech + 1) * 4096 + 8_000 < samples.count {
                let own = Array(samples[..<((lastSpeech + 1) * 4096 + 8_000)])
                out["parakeet_live"] = await SpeechLab.shared.transcribe(own, localeIdentifier: locale) as Any? ?? NSNull()
            }
            out["speech_model"] = ["speech_seconds": Double(mine.filter { $0 }.count) * 0.256,
                                   "last_speech_at": lastSpeech.map { Double($0 + 1) * 0.256 } as Any? ?? NSNull()] as [String: Any]
            out["loudness"] = ["voiced_seconds": Double(loud.filter { $0 }.count) * 0.256,
                               "last_voiced_at": loud.lastIndex(of: true).map { Double($0 + 1) * 0.256 } as Any? ?? NSNull()] as [String: Any]
            return Response(status: 200, json: out)
        // MARK: Stage: the screen shows and says exactly what the driver gives it. No model is
        // called, nothing is recognised; made for recording a video.
        case ("POST", "/stage/upload"):
            // A picture for later stage calls. Faces and plates are masked here, as on every
            // frame Muisti shows; a private view (bathroom, card keypad) is refused.
            guard let jpeg = ImageData.ensureJPEG(request.body) else { return Response(status: 400, json: ["error": "send a picture as the body (Content-Type: image/jpeg)"]) }
            let raw = request.query["raw"] == "1"
            let prepared = raw ? nil : await Task.detached(priority: .userInitiated) { SafetyFrame.prepare(jpeg, maxPixel: 1536, fromPipeline: false) }.value
            guard raw || prepared != nil else { return Response(status: 422, json: ["error": "this picture is withheld (a private view, or it could not be masked)"]) }
            let name = (request.query["name"] ?? UUID().uuidString.prefix(8).lowercased()) + ".jpg"
            try? FileManager.default.createDirectory(at: Self.stageDirectory, withIntermediateDirectories: true)
            try? (prepared?.jpeg ?? jpeg).write(to: Self.stageDirectory.appendingPathComponent(name))
            return Response(status: 200, json: ["file": name, "text_read": prepared?.ocr ?? ""])
        case ("POST", "/stage/turn"):
            // One whole turn: the question arrives word by word, Muisti thinks, the answer is
            // shown with its pictures and read aloud. Every part is optional except `answer`.
            guard let answer = text("answer"), !answer.isEmpty else { return Response(status: 400, json: ["error": "answer is missing"]) }
            let voice = controller.voice
            let question = text("question") ?? ""
            let proactive = (value("proactive") as? Bool) == true || question.isEmpty
            if !question.isEmpty {
                let words = Double(question.split(separator: " ").count)
                await voice.stageHeard(question, seconds: number("heard_seconds") ?? max(1.0, words * 0.33))
                await voice.stageThinking(question, seconds: number("think_seconds") ?? 1.2, tone: (value("tone") as? Bool) != false)
            }
            let label: AnswerLabel = switch text("label") ?? "seen" {
            case "not_seen": .unknown
            case "unsure": .unsure
            default: .seen
            }
            var hits: [MemoryHit] = []
            for id in (value("evidence_ids") as? [Any] ?? []).compactMap({ ($0 as? NSNumber)?.int64Value }) {
                if let record = await controller.store.record(id: id) { hits.append(MemoryHit(record: record, score: 1)) }
            }
            let pictures = (value("images") as? [String] ?? []).map { Self.stageDirectory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let live = text("live_image").flatMap { try? Data(contentsOf: Self.stageDirectory.appendingPathComponent($0)) }
            // `chat`: a plain reply with no "Seen / Not seen" chip (small talk, a command, Muisti speaking first).
            let plain = text("label") == "chat" || proactive
            let result = AskResult(question: proactive ? (text("title") ?? String(localized: "Muisti noticed")) : question, answer: answer, label: label,
                                   evidence: hits, usedAI: true, latencyMs: 0, note: text("note"), language: text("language"),
                                   isCommand: plain, safetyFrames: pictures, spontaneous: proactive, liveFrame: live)
            await voice.stageAnswer(result, speak: (value("speak") as? Bool) != false)
            return Response(status: 200, json: ["shown": true, "evidence": hits.map { Int($0.record.id) }, "pictures": pictures.count, "live_image": live != nil])
        case ("POST", "/stage/phase"):
            // Hold one view: idle, listening, thinking or speaking, with optional words on screen.
            guard let phase = text("phase"), ["idle", "listening", "thinking", "speaking"].contains(phase) else {
                return Response(status: 400, json: ["error": "phase: idle, listening, thinking or speaking"])
            }
            controller.voice.stagePhase(phase, text: text("text"))
            return Response(status: 200, json: ["phase": phase])
        case ("POST", "/stage/view"):
            // The picture shown as what the camera sees (the preview on the Recording screen).
            guard let name = text("image"), let data = try? Data(contentsOf: Self.stageDirectory.appendingPathComponent(name)), let image = UIImage(data: data) else {
                return Response(status: 400, json: ["error": "image: a file name from /stage/upload"])
            }
            controller.stagePreview(image)
            return Response(status: 200, json: ["showing": name])
        case ("POST", "/stage/memory"):
            // A memory written exactly as given (Memory tab, map, evidence cards): no analysis call.
            guard let name = text("image"), let jpeg = try? Data(contentsOf: Self.stageDirectory.appendingPathComponent(name)) else {
                return Response(status: 400, json: ["error": "image: a file name from /stage/upload"])
            }
            let at = text("at").flatMap { Cue(at: $0).nextDue(after: Date.distantPast) } ?? Date()
            let seenAt = number("minutes_ago").map { Date().addingTimeInterval(-$0 * 60) } ?? at
            guard let id = await controller.store.insert(NewMemory(seenAt: seenAt, latitude: number("lat"), longitude: number("lon"), accuracy: number("lat") == nil ? nil : 10,
                                                                   heading: nil, street: text("street"), area: text("area"), ocrText: text("text") ?? "", frameJPEG: jpeg)) else {
                return Response(status: 500, json: ["error": "the memory could not be written"])
            }
            var fields: [String: Any] = ["useful": true, "kind": text("kind") ?? "other", "objects": [Any](), "relations": [Any](), "depictions": [Any](), "confidence": 0.95]
            for key in ["name", "subtype", "phone", "hours", "other_text", "caption"] { if let given = text(key) { fields[key] = given } }
            if let keywords = value("keywords") as? [String] { fields["keywords"] = keywords }
            guard let json = try? JSONSerialization.data(withJSONObject: fields), let record = try? JSONDecoder().decode(ExtractedRecord.self, from: json) else {
                return Response(status: 500, json: ["error": "the record fields could not be read", "id": Int(id)])
            }
            await controller.store.applyEnrichment(id: id, record: record, embedding: nil, model: "")
            return Response(status: 200, json: ["id": Int(id), "seen_at": Cue.stamp(seenAt)])
        case ("POST", "/stage/status"):
            // The status island at the top: "recording" (glasses connected and remembering),
            // "off", or "real" (what the glasses are actually doing). `battery`: the glasses' percentage.
            guard let glasses = text("glasses"), ["recording", "off", "real"].contains(glasses) else {
                return Response(status: 400, json: ["error": "glasses: recording, off or real"])
            }
            UserDefaults.standard.set(glasses == "real" ? nil : glasses, forKey: DeveloperMode.stageStatusKey)
            UserDefaults.standard.set(Int(number("battery") ?? 0), forKey: DeveloperMode.stageBatteryKey)
            // The screen redraws on the next change; nudge it now.
            controller.voice.stagePhase("idle", text: nil)
            NotificationCenter.default.post(name: Self.showScreen, object: "ask")
            return Response(status: 200, json: ["glasses": glasses])
        case ("POST", "/stage/clear"):
            controller.voice.stagePhase("idle", text: "")
            controller.voice.clearConversation()
            return Response(status: 200, json: ["cleared": true])
        case ("GET", "/habits"):
            let now = Date()
            return Response(status: 200, json: ["habits": Habits.lines(await controller.agent.habits(now: now), now: now)])
        case ("POST", "/screen"):
            // What the phone shows (for a screen recording): ask, memory, safety, notes.
            guard let name = text("show"), ["ask", "memory", "safety", "notes", "back"].contains(name) else {
                return Response(status: 400, json: ["error": "show: ask, memory, safety, notes or back"])
            }
            NotificationCenter.default.post(name: Self.showScreen, object: name)
            return Response(status: 200, json: ["showing": name])
        case ("POST", "/reset"):
            guard text("confirm") == "yes" else { return Response(status: 400, json: ["error": "this deletes all memories, rules and notes: send {\"confirm\": \"yes\"}"]) }
            videoTask?.cancel()
            await controller.deleteAllMemories()
            controller.voice.clearConversation()
            liveBox.set(nil)
            return Response(status: 200, json: ["reset": true])
        default:
            return Response(status: 404, json: ["error": "unknown route \(request.method) \(request.path)",
                                                "routes": ["GET /state", "GET /events?since=", "GET /evidence?id=", "GET /wait-idle?timeout=", "POST /ask", "POST /frame", "POST /video",
                                                           "POST /location", "POST /motion", "POST /tick", "POST /reply", "POST /reset", "GET /chat", "POST /chat/clear",
                                                           "GET /memories?limit=", "POST /memory/delete", "POST /forget", "POST /intent", "POST /rule",
                                                           "POST /settings", "POST /screen", "POST /speech",
                                                           "POST /stage/upload", "POST /stage/turn", "POST /stage/phase", "POST /stage/view", "POST /stage/memory", "POST /stage/status", "POST /stage/clear"]])
        }
    }

    // MARK: Seeing

    /// One picture as what the glasses see at `at`: the live view for "what is this?", and (when
    /// stored) a frame through the same steps as a captured one.
    private func show(_ jpeg: Data, at: Date, store: Bool) async -> [String: Any] {
        let prepared = await Task.detached(priority: .userInitiated) { SafetyFrame.prepare(jpeg, maxPixel: 1536, fromPipeline: false) }.value
        if let prepared { liveBox.set((prepared.jpeg, prepared.ocr, at)) }
        var kept = false
        if store {
            let frame = CapturedFrame(capturedAt: at, origin: .glassesStream, jpeg: jpeg, pixelSize: ImageData.pixelSize(of: jpeg),
                                      isHighRes: false, trigger: .interval)
            kept = await controller.driverFeed(frame)
        }
        return ["kept": kept, "withheld": prepared == nil, "text_read": prepared?.ocr ?? ""]
    }

    /// Plays a video file as the glasses' view: a frame every `step` seconds of the video, fed
    /// `speed` times faster than real time (0: as fast as they can be processed), each stamped
    /// with its own moment (now + its time in the video).
    private func play(path: String, step: Double, speed: Double, track: [(t: Double, lat: Double, lon: Double)], motion: String?) async -> [String: Any] {
        videoTask?.cancel()
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return ["error": "the video could not be read"] }
        if let kind = motion.flatMap(MotionActivityKind.init(rawValue:)) { controller.motion.simulate(kind) }
        let planned = Int(duration / step) + 1
        video = VideoProgress(file: (path as NSString).lastPathComponent, planned: planned, fed: 0, kept: 0, running: true)
        let began = Date()
        videoTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2400, height: 2400)
            let tolerance = CMTime(seconds: min(0.25, step / 2), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            var t = 0.0
            while t <= duration, !Task.isCancelled, let self {
                defer { t += step }
                let started = ContinuousClock.now
                guard let (image, actual) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                      let jpeg = ImageData.encodeJPEG(image, quality: 0.85) else { continue }
                let at = began.addingTimeInterval(actual.seconds)
                // The position recorded for this moment of the video, if a track was given.
                if let point = track.last(where: { $0.t <= actual.seconds }) ?? track.first {
                    self.controller.location.inject(CLLocation(coordinate: .init(latitude: point.lat, longitude: point.lon), altitude: 0,
                                                               horizontalAccuracy: 8, verticalAccuracy: 8, course: -1, speed: 1.3, timestamp: at))
                    await self.controller.agent.navigationFix(self.controller.location.latest!)
                }
                let result = await self.show(jpeg, at: at, store: true)
                self.video.fed += 1
                if result["kept"] as? Bool == true { self.video.kept += 1 }
                if speed > 0 {
                    let wait = step / speed - (ContinuousClock.now - started).seconds
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                }
            }
            self?.video.running = false
        }
        return ["playing": video.file, "seconds": duration, "frames_planned": planned, "step": step, "speed": speed]
    }

    // MARK: Talking

    private func ask(_ question: String) async -> [String: Any] {
        await controller.voice.ask(question)
        guard let result = controller.voice.lastResult else { return ["error": "no answer"] }
        let store = controller.store
        var out: [String: Any] = [
            "answer": result.answer,
            "label": result.label.rawValue,
            "language": orNull(result.language),
            "latency_ms": result.latencyMs,
            "expects_reply": result.expectsReply,
            "is_command": result.isCommand,
            "trace": result.trace ?? "",
            "evidence": result.evidence.map { hit -> [String: Any] in
                ["id": hit.record.id, "title": hit.record.title, "seen_at": ISO8601DateFormatter().string(from: hit.record.seenAt),
                 "street": orNull(hit.record.street), "frame": store.frameURL(hit.record).path]
            },
            "safety_frames": result.safetyFrames.map(\.path),
            "looked_live": result.liveFrame != nil,
        ]
        if let note = result.note { out["note"] = note }
        return out
    }

    /// JSON has no "nothing" but null.
    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }
    private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private static func levelName(_ level: InterventionLevel) -> String {
        switch level {
        case .silent: return "silent"
        case .notification: return "notification"
        case .chime: return "chime"
        case .spoken: return "spoken"
        }
    }

    /// Everything Muisti brought up by itself (or chose not to) after entry `since`, oldest first.
    private func events(since: Int64) async -> [String: Any] {
        let all = await controller.agent.store.interventions(since: Date().addingTimeInterval(-7 * 86_400), limit: 1000)
        let fresh = all.filter { $0.id > since }.sorted { $0.id < $1.id }
        let stamp = ISO8601DateFormatter()
        return ["last": all.map(\.id).max() ?? since,
                "events": fresh.map { e -> [String: Any] in
                    ["id": e.id, "at": stamp.string(from: e.at), "source": e.source, "topic": e.topic, "urgency": e.urgency.rawValue,
                     "level": Self.levelName(e.level), "text": e.text, "reason": orNull(e.reason), "outcome": orNull(e.outcome?.rawValue),
                     "intent": orNull(e.intentID), "record": orNull(e.recordID)]
                }]
    }

    private func state() async -> [String: Any] {
        let agent = controller.agent
        let counts = await controller.store.count()
        let fix = controller.location.latest
        var route: Any = NSNull()
        if let guide = agent.route {
            var info: [String: Any] = ["to": guide.name, "meters_left": Int(guide.remainingMeters), "steps": guide.steps.map(\.instruction).filter { !$0.isEmpty }]
            if let fix, let next = guide.upcoming(from: fix.clLocation) { info["next_turn"] = next.instruction; info["next_turn_meters"] = Int(next.meters) }
            route = info
        }
        return [
            "memories": counts.total,
            "frames_waiting": counts.pending,
            "video": ["file": video.file, "running": video.running, "fed": video.fed, "planned": video.planned, "kept": video.kept],
            "position": orNull(controller.location.positionText()),
            "motion": controller.motion.activity.rawValue,
            "intents": agent.intents.map { i -> [String: Any] in
                ["id": i.id, "kind": i.kind.rawValue, "text": i.text, "say": orNull(i.say), "source": i.source.rawValue,
                 "cue": ["at": orNull(i.cue.at), "daily": orNull(i.cue.daily), "place": orNull(i.cue.place),
                         "sight": orNull(i.cue.sight), "on": orNull(i.cue.on)],
                 "place_name": orNull(i.placeName)]
            },
            "route": route,
            "places": agent.places.map { ["name": $0.name, "detail": orNull($0.detail), "lat": $0.latitude, "lon": $0.longitude] as [String: Any] },
            "facts": agent.facts.map(\.text),
            "agent_pending": orNull(agent.pending?.prompt),
            "last_judgement": agent.lastJudgement,
            "safety": [
                "rules": controller.safety.rules.map { ["id": $0.id, "summary": $0.summary, "enabled": $0.enabled] as [String: Any] },
                "states": controller.safety.states.map { ["object": $0.object, "state": $0.state] },
                "pending": orNull(controller.safety.pending?.prompt),
                "open_alerts": controller.safety.alerts.filter { $0.response == nil }.prefix(10).map(\.message),
            ] as [String: Any],
            "conversation_notes": agent.promptContext(),
        ]
    }

    /// Until the video has been fed and every frame is structured and embedded.
    private func waitIdle(seconds: Double) async -> [String: Any] {
        let began = ContinuousClock.now
        while (ContinuousClock.now - began).seconds < seconds {
            let counts = await controller.store.count()
            let embedded = await controller.store.missingEmbeddings(limit: 1).isEmpty
            if !video.running, counts.pending == 0, embedded, !controller.agent.isWeighing {
                // A frame's enrichment hands it to the agent a moment later: look once more.
                try? await Task.sleep(for: .milliseconds(700))
                guard !controller.agent.isWeighing, await controller.store.count().pending == 0 else { continue }
                return ["idle": true, "memories": counts.total, "waited_seconds": (ContinuousClock.now - began).seconds]
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return ["idle": false, "waited_seconds": seconds]
    }
}
#endif
