import CoreLocation
import Foundation

/// Arguments of the look-up tools (lenient: a model may send numbers as text).
struct ReadArgs: Decodable, Sendable {
    var query: String?
    var object: String?
    var hours: Double?
    var key: String?
    var value: String?
    var minutes: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = c.lenientString(.query)
        object = c.lenientString(.object)
        hours = c.lenientDouble(.hours)
        key = c.lenientString(.key)
        value = c.lenientString(.value)
        minutes = c.lenientDouble(.minutes)
    }

    enum CodingKeys: String, CodingKey { case query, object, hours, key, value, minutes }
}

/// What the look-up tools run against (built by `CaptureController`, which owns the stores).
struct ReadToolbox: Sendable {
    var run: @Sendable (_ name: String, _ args: ReadArgs?) async -> String
}

/// The agent loop shared by the user's turn and Muisti's own judgement (pipeline v2, §5.2):
/// the model may first look things up — the conversation of earlier, the state of a thing it
/// tracks, the safety log, the route, the calendar, the map, the memory — and then decides
/// with one of the caller's own tools. At most `maxSteps` model calls; the last one offers the
/// deciding tools only. Looking things up has no side effects (the one exception keeps a note
/// for Muisti itself), so several look-ups of one step run side by side.
enum AgentLoop {
    private static func tool(_ name: String, _ description: String, _ properties: [String] = [], required: [String] = []) -> String {
        let escaped = (try? JSONSerialization.data(withJSONObject: [description]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() } ?? "\"\""
        let need = required.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"function","function":{"name":"\#(name)","description":\#(escaped),"parameters":{"type":"object","properties":{\#(properties.joined(separator: ","))},"required":[\#(need)]}}}"#
    }

    private static let common: [String] = [
        tool("recall_dialog", """
             Look up what was said earlier between you and the user, today or on earlier days, \
             when it is not in the conversation shown to you ("what did I tell you this morning", \
             a name, a number or a plan they mentioned before). Returns the turns that match. Not \
             for what the glasses saw.
             """, [#""query":{"type":"string","description":"The words to look for, as they would have been said."}"#], required: ["query"]),
        tool("object_state", """
             The last known state of one thing: whether it was on or off, open or closed, where \
             and when it was last seen, from the safety log and the memory ("is the stove still \
             on", "where are my keys", "do I have milk at home"). What comes back is what was \
             last SEEN, with its time; it may have changed since.
             """, [#""object":{"type":"string","description":"The thing, in one or two words."}"#], required: ["object"]),
        tool("safety_log", "Muisti Turva's log of the last hours: what was seen done, switched, taken or left, newest first.",
             [#""hours":{"type":"number","description":"How many hours back; 24 when unsure."}"#,
              #""object":{"type":["string","null"],"description":"Only entries about this thing; null for all."}"#], required: ["hours"]),
        tool("route_status", "Where the user is heading right now, how far it is and the next turn."),
        tool("calendar", "The user's calendar for the next 24 hours (only when they allowed it)."),
        tool("places", "What the map shows near the user's position now for some words (a café, a pharmacy). These are map results, not things the glasses saw.",
             [#""query":{"type":"string","description":"What to look for on the map."}"#], required: ["query"]),
        tool("note_to_self", """
             Keep a short note for yourself for a while: something about the user's situation that \
             should shape what you say or keep to yourself later (in a meeting until three, \
             waiting for someone, does not want to be disturbed, on the way to the gym). The note \
             is shown to you in every later turn and judgement until it expires. Call it together \
             with nothing else; you decide what to say in the next step.
             """, [#""key":{"type":"string","description":"Two or three words naming the note, so a later note on the same thing replaces it."}"#,
                   #""value":{"type":"string","description":"The note, one sentence."}"#,
                   #""minutes":{"type":["number","null"],"description":"How long it holds; null when it was not said (two hours are assumed)."}"#],
             required: ["key", "value"]),
    ]

    /// Look-ups offered before the user's turn is decided. The state of things and the safety
    /// log are not among them: a turn about those ends in search_memory or look_now, whose
    /// answers are checked against the evidence (with these two offered, "is the stove on?" was
    /// answered from the log with `say`, unchecked, instead of by looking: 15 Nov).
    static let turnReads = "[" + common.filter { !$0.contains(#""name":"object_state""#) && !$0.contains(#""name":"safety_log""#) }.joined(separator: ",") + "]"
    /// The agent's own judgement can also search the memory itself before it speaks.
    static let judgeReads = "[" + (common + [
        tool("find_in_memory", "Search what the glasses saw earlier (signs, places, objects, prices) for something that bears on what you are about to say. Returns the best records with their time and place.",
             [#""query":{"type":"string","description":"What to look for, complete by itself."}"#], required: ["query"]),
    ]).joined(separator: ",") + "]"

    private static func names(_ tools: String) -> Set<String> {
        guard let list = try? JSONSerialization.jsonObject(with: Data(tools.utf8)) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }

    private static func merged(_ a: String, _ b: String) -> String {
        "[" + a.dropFirst().dropLast() + "," + b.dropFirst().dropLast() + "]"
    }

    struct Outcome: Sendable {
        var reply: NemotronClient.ToolReply
        /// What was looked up on the way ("object_state(stove)"), for the trace.
        var lookedUp: [String] = []
        /// The results, as the model read them (they count as shown for the evidence check).
        var shown: String = ""
    }

    static func run(_ ai: NemotronClient, system: String, user: String, decide: String, reads: String, toolbox: ReadToolbox?,
                    image: NemotronClient.ImagePart? = nil, maxTokens: Int = 400, route: NemotronClient.Route? = nil,
                    background: Bool = false, maxSteps: Int = 3) async throws -> Outcome {
        guard let toolbox, maxSteps > 1 else {
            return Outcome(reply: try await ai.chatTools(system: system, user: user, tools: decide, image: image, maxTokens: maxTokens,
                                                         route: route, background: background))
        }
        let readNames = names(reads)
        var text = user
        var out = Outcome(reply: .init(text: "", calls: []))
        for step in 1...maxSteps {
            let last = step == maxSteps
            let reply = try await ai.chatTools(system: system, user: text, tools: last ? decide : merged(decide, reads), image: image,
                                               maxTokens: maxTokens, route: route, background: background)
            let lookUps = reply.calls.filter { readNames.contains($0.name) }
            let decisions = reply.calls.filter { !readNames.contains($0.name) }
            if !decisions.isEmpty || last {
                out.reply = .init(text: reply.text, calls: decisions)
                return out
            }
            if lookUps.isEmpty {
                // Neither a look-up nor a decision came back (seen with the longer tool list):
                // once more with the deciding tools only.
                Trace.note("agent loop: no usable call at step \(step) (\(reply.calls.map(\.name).joined(separator: ", "))); deciding tools only")
                out.reply = try await ai.chatTools(system: system, user: text, tools: decide, image: image, maxTokens: maxTokens,
                                                   route: route, background: background)
                return out
            }
            let results = await withTaskGroup(of: (Int, String).self) { group -> [String] in
                for (i, call) in lookUps.prefix(4).enumerated() {
                    group.addTask { (i, "- \(call.name)(\(call.arguments.prefix(120))) →\n\(await toolbox.run(call.name, call.decode(ReadArgs.self)))") }
                }
                var collected: [(Int, String)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            out.lookedUp += lookUps.prefix(4).map { "\($0.name)(\($0.arguments.prefix(40)))" }
            let block = results.joined(separator: "\n")
            out.shown += "\n" + block
            text += "\n\nWhat you looked up (step \(step)); decide now, or look up what is still missing:\n" + block
        }
        return out
    }
}

extension ReadToolbox {
    /// The look-ups against the phone's own stores.
    @MainActor
    static func make(memory: MemoryStore, ai: NemotronClient, dialog: DialogStore, safety: SafetyMonitor, agent: AgentCenter,
                     location: LocationProvider) -> ReadToolbox {
        let safetyStore = safety.store
        return ReadToolbox { name, args in
            let now = Date()
            switch name {
            case "recall_dialog":
                let found = await dialog.search(args?.query ?? "")
                return found.isEmpty ? "(nothing was said about that)" : found.map { "\(Cue.stamp($0.at)) " + ContextBuilder.line($0) }.joined(separator: "\n")
            case "object_state":
                let object = (args?.object ?? "").lowercased()
                guard !object.isEmpty else { return "(no object named)" }
                var lines: [String] = []
                for state in await safetyStore.states() where state.object.lowercased().contains(object) || object.contains(state.object.lowercased()) {
                    lines.append("\(state.object): \(state.state) since \(QueryEngine.promptTime(state.since)), last seen \(QueryEngine.promptTime(state.lastSeen))"
                                 + (state.place.map { ", \($0)" } ?? "") + " (source: \(state.source.rawValue))")
                }
                let events = await safetyStore.events(since: now.addingTimeInterval(-48 * 3600), limit: 400)
                    .filter { ($0.object ?? "").lowercased().contains(object) }.prefix(4)
                lines += events.map { "log \(QueryEngine.promptTime($0.at)): \($0.object ?? "") \($0.value ?? "") (\($0.source.rawValue))" + ($0.detail.map { " — \($0)" } ?? "") }
                let vector = try? await ai.embed(object, as: .query)
                let seen = await memory.search(MemorySearch(keywords: [object], embedding: vector, limit: 6)).prefix(2)
                lines += seen.map { "memory record \($0.record.id), seen \(QueryEngine.promptTime($0.record.seenAt))\($0.record.street.map { ", \($0)" } ?? ""): \($0.record.title)\($0.record.caption.map { " — \($0.prefix(160))" } ?? "")" }
                return lines.isEmpty ? "(nothing known about \(object))" : lines.joined(separator: "\n")
            case "safety_log":
                let hours = min(max(args?.hours ?? 24, 1), 24 * 14)
                let object = args?.object?.lowercased()
                let events = await safetyStore.events(since: now.addingTimeInterval(-hours * 3600), limit: 300)
                    .filter { e in object.map { (e.object ?? "").lowercased().contains($0) } ?? true }.prefix(25)
                return events.isEmpty ? "(nothing in the log)" : events.map {
                    "\(QueryEngine.promptTime($0.at)): \($0.object ?? "-") \($0.value ?? "") [\($0.kind.rawValue), \($0.source.rawValue)]"
                }.joined(separator: "\n")
            case "route_status":
                let lines = await agent.promptContext(now: now).split(separator: "\n").filter { $0.hasPrefix("Destination") || $0.hasPrefix("Walking route") }
                return lines.isEmpty ? "(no destination)" : lines.joined(separator: "\n")
            case "calendar":
                var take = false
                var lines: [Substring] = []
                for line in await agent.promptContext(now: now).split(separator: "\n") {
                    if line.hasPrefix("User's calendar") { take = true; lines.append(line); continue }
                    if take { if line.hasPrefix("- ") { lines.append(line) } else { break } }
                }
                return lines.isEmpty ? "(the calendar is not shared with Muisti)" : lines.joined(separator: "\n")
            case "places":
                guard await agent.settings.mapSearch else { return "(map look-ups are switched off)" }
                guard let fix = await location.freshFix(maxAge: 300) else { return "(the position is not known right now)" }
                let here = fix.clLocation
                let found = await Places.search(args?.query ?? "", near: here.coordinate, radius: 1000).prefix(5)
                return found.isEmpty ? "(the map shows nothing like that within 1 km)" : found.map {
                    "\($0.name), about \(Int(($0.location.distance(from: here) / 10).rounded()) * 10) m away (map result, not seen)"
                }.joined(separator: "\n")
            case "note_to_self":
                guard let key = args?.key, let value = args?.value, !value.isEmpty else { return "(nothing to note)" }
                let minutes = min(max(args?.minutes ?? 120, 1), 24 * 60)
                await dialog.remember(key: key.lowercased(), value: value, ttl: minutes * 60, now: now)
                return "noted for \(Int(minutes)) minutes: \(value)"
            case "find_in_memory":
                let query = args?.query ?? ""
                let vector = try? await ai.embed(query, as: .query)
                let found = await memory.search(MemorySearch(keywords: [query], embedding: vector, limit: 8)).prefix(5)
                return found.isEmpty ? "(nothing in memory)" : found.map {
                    "record \($0.record.id), seen \(QueryEngine.promptTime($0.record.seenAt))\($0.record.street.map { ", \($0)" } ?? ""): \($0.record.title)\($0.record.caption.map { " — \($0.prefix(200))" } ?? "")"
                }.joined(separator: "\n")
            default:
                return "(unknown tool)"
            }
        }
    }
}
