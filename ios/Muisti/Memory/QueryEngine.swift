import Foundation
import NaturalLanguage
import UIKit

struct AskResult: Sendable, Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    let label: AnswerLabel
    let evidence: [MemoryHit]
    let usedAI: Bool
    let latencyMs: Int
    let note: String?
    /// ISO 639-1 language of the question, as Nemotron reported it (drives the spoken voice).
    var language: String?
    /// Stage timings and retrieval facts, for the developer view and logs.
    var trace: String?
    /// Record ids of each context group, best first (evaluation / debugging).
    var ranked: [[Int64]] = []
    /// Muisti Turva command carried by this reply (run by the voice assistant).
    var safety: SafetyCommand?
    /// Agent command carried by this reply (an intent, a destination, a mute…), run the same way.
    var agent: AgentCommand?
    /// A command reply (rule, forget, log) rather than an answer about something seen.
    var isCommand = false
    /// Evidence frames from the safety log the reply relies on.
    var safetyFrames: [URL] = []
    /// Muisti spoke first (a warning or a question): no user question to show.
    var spontaneous = false
    /// The reply asks the user something back: a voice conversation keeps listening.
    var expectsReply = false
    /// The live view the reply looked at (shown as its evidence).
    var liveFrame: Data?
}

/// What the answer engine needs from Muisti Turva, without depending on its actor.
struct SafetyBridge: Sendable {
    var context: @Sendable () async -> String
    var forget: @Sendable (Date) async -> Void
    var frames: @Sendable ([Int64]) async -> [URL]
}

/// On-phone RAG over everything the glasses saw:
/// question → Nemotron query embedding → hybrid retrieval on the phone (FTS5 + in-memory
/// vectors + partial-read matching + recency, fused by rank) → grouping of repeated reads of
/// the same sign → Nemotron 3.5 rerank → one Nemotron call that understands the question
/// (language, time/place references, forget requests) and answers from the records only →
/// evidence rule on every number and quote.
///
/// There is deliberately no hand-written language parsing here (no keyword lists, no regexes
/// for "just now"/"here"/"forget"): understanding the question is the model's job, steered by
/// `MemoryPrompts.answerSystem`.
actor QueryEngine {
    private let store: MemoryStore
    private let ai: NemotronClient
    /// Ranked groups of the question being answered (copied into the result).
    private var rankedForResult: [[Int64]] = []
    private var safety: SafetyBridge?
    /// Tool for the answer model: a live picture from the glasses (faces masked) with its OCR.
    private var liveView: (@Sendable () async -> (jpeg: Data, ocr: String, at: Date)?)?

    func setLiveView(_ provider: @escaping @Sendable () async -> (jpeg: Data, ocr: String, at: Date)?) { liveView = provider }
    private var lastLive: (jpeg: Data, ocr: String, at: Date)?
    /// This answer looked through the glasses (shown under the answer).
    private var lookedLive = false
    /// The last question and reply, so "yes" / "not now" can answer what Muisti just said.
    /// The conversation so far (last few turns), so follow-ups ("what was next to it?", "and
    /// the phone number?", "yes") are understood, with the records each reply relied on.
    struct Turn: Sendable {
        var question: String
        var answer: String
        var ids: [Int64]
        var at: Date
        /// This reply looked through the glasses (its frame stays in view for follow-ups).
        var looked = false
    }
    private var conversation: [Turn] = []
    /// The conversation on disk (pipeline v2): every turn in both directions, summaries of
    /// older turns and Muisti's own short notes. What the models read as "conversation so far"
    /// is built from it (`ContextBuilder`), so it survives a restart and is not cut to the last
    /// few minutes; the array above only serves the mechanics of follow-ups (which records the
    /// last reply relied on, whether it looked).
    nonisolated let dialog = DialogStore()
    /// Writes to the dialog in the order they were made; readers wait for the last one.
    private var dialogWrites: Task<Int64, Never>?
    private var dialogLoaded = false
    /// The tool this turn ended in, written next to the reply.
    private var lastTool: String?
    static let spokeFirst = "(Muisti spoke first)"

    private func remember(_ turn: Turn) {
        conversation.append(turn)
        if conversation.count > 12 { conversation.removeFirst(conversation.count - 12) }
        let dialog = self.dialog, previous = dialogWrites, tool = lastTool, ai = self.ai
        dialogWrites = Task {
            _ = await previous?.value
            if turn.question != Self.spokeFirst {
                await dialog.append(DialogTurn(at: turn.at, speaker: .user, text: turn.question))
            }
            let id = await dialog.append(DialogTurn(at: turn.at, speaker: turn.question == Self.spokeFirst ? .proactive : .muisti,
                                                    text: turn.answer, tool: tool, recordIDs: turn.ids, looked: turn.looked))
            Task { await ContextBuilder.summarizeIfNeeded(dialog, ai: ai) }
            return id
        }
    }

    /// After a restart: the last turns come back from disk, so a follow-up still knows what
    /// the previous reply relied on.
    private func loadDialogIfNeeded() async {
        guard !dialogLoaded else { return }
        dialogLoaded = true
        guard conversation.isEmpty else { return }
        var question: DialogTurn?
        var restored: [Turn] = []
        for turn in await dialog.latest(limit: 16) {
            switch turn.speaker {
            case .user: question = turn
            case .muisti:
                restored.append(Turn(question: question?.text ?? "", answer: turn.text, ids: turn.recordIDs, at: turn.at, looked: turn.looked))
                question = nil
            case .proactive: restored.append(Turn(question: Self.spokeFirst, answer: turn.text, ids: turn.recordIDs, at: turn.at))
            case .note: break
            }
        }
        if conversation.isEmpty { conversation = Array(restored.suffix(12)) }
    }

    /// "Conversation so far" for a prompt: summaries, Muisti's notes and the latest turns.
    func dialogLines(now: Date = Date()) async -> [String] {
        _ = await dialogWrites?.value
        return await ContextBuilder.conversation(dialog, now: now)
    }

    /// Muisti spoke first (a warning or a yes/no question).
    func noteMuistiSaid(_ text: String) {
        lastTool = nil
        remember(Turn(question: Self.spokeFirst, answer: text, ids: [], at: Date()))
    }

    /// The reply actually given (a warning may replace the model's acknowledgement).
    func noteExchange(question: String, answer: String) {
        if let last = conversation.last, last.question == question {
            conversation[conversation.count - 1].answer = answer
            let dialog = self.dialog, previous = dialogWrites
            dialogWrites = Task {
                let id = await previous?.value ?? 0
                if id > 0 { await dialog.setText(id: id, answer) }
                return id
            }
        } else {
            remember(Turn(question: question, answer: answer, ids: [], at: Date()))
        }
    }

    /// Starts a new conversation (the chat was cleared): the turns are no longer read word for
    /// word; what was summarised before stays.
    func clearConversation() {
        conversation = []
        lastLive = nil
        dialogLoaded = true
        let dialog = self.dialog, previous = dialogWrites
        dialogWrites = Task {
            let id = await previous?.value ?? 0
            await dialog.startSession()
            return id
        }
    }

    /// Forgets the whole conversation, summaries and notes included (delete everything; tests).
    func resetConversation() async {
        conversation = []
        lastLive = nil
        dialogLoaded = true
        _ = await dialogWrites?.value
        dialogWrites = nil
        await dialog.deleteAll()
    }

    func setSafety(_ bridge: SafetyBridge) { safety = bridge }

    /// Turns a place the user named ("Istanbul", "work", "here") into an area on the map.
    private var placeResolver: (@Sendable (String, LocationFix?) async -> MemoryArea?)?
    func setPlaceResolver(_ resolver: @escaping @Sendable (String, LocationFix?) async -> MemoryArea?) { placeResolver = resolver }
    private var areas: [String: MemoryArea] = [:]
    /// What the map shows around a position for some words ("café"), as lines for the model.
    private var nearbyPlaces: (@Sendable (String, LocationFix) async -> [String])?
    func setNearbyPlaces(_ search: @escaping @Sendable (String, LocationFix) async -> [String]) { nearbyPlaces = search }
    /// The look-up tools of the agent loop (earlier conversation, object states, log, map).
    private var toolbox: ReadToolbox?
    func setToolbox(_ box: ReadToolbox) { toolbox = box }
    /// A full-resolution photo of the present view (slower than a stream frame, and the
    /// glasses make their capture sound): for a look whose first frame was too small to read.
    private var sharpView: (@Sendable () async -> (jpeg: Data, ocr: String, at: Date)?)?
    func setSharpView(_ provider: @escaping @Sendable () async -> (jpeg: Data, ocr: String, at: Date)?) { sharpView = provider }
    /// Whether the glasses are sending pictures now (nil: not known, as in tests).
    private var cameraLive: (@Sendable () async -> Bool)?
    func setCameraLive(_ live: @escaping @Sendable () async -> Bool) { cameraLive = live }

    private func area(named name: String, here: LocationFix?) async -> MemoryArea? {
        let key = name.lowercased()
        if key != "here", let known = areas[key] { return known }
        let found: MemoryArea?
        if let placeResolver { found = await placeResolver(name, here) }
        else { found = await Places.area(name, known: [], here: here, maps: true) }
        if let found, key != "here" { areas[key] = found }
        return found
    }

    /// Groups shown to the answer model.
    static let answerContext = 8
    /// Episodes (with their frames) shown to the answer model.
    static let episodeContext = 3
    /// Frames shown per episode.
    static let framesPerEpisode = 14
    /// Reranker logit above which the top record is very likely relevant. Measured on the
    /// 80-question simulator set: questions about things never seen topped out at -2.94;
    /// wrongly refused answers had -2.04…-2.71.
    static let secondLookLogit = -2.8
    /// Whether the model thinks first when the turn says an answer needs working out. Off:
    /// measured 15 Nov on the look set, thinking took the same sums from 2–3 s to 10–13 s and
    /// solved nothing that was not already solved without it (11 of 11); on the phone it read
    /// as "it cannot solve it and waits forever". The switch and the turn's `reasoning_needed`
    /// stay, for a model or a question set where it pays.
    static let thinkingForWorkedAnswers = false
    /// Below this, the reranker saw nothing in a record that answers the question.
    static let unsupportedLogit = -3.1
    /// Added to the reranker's logit for records made where the user is now (same venue).
    static let sameVenueBonus = 0.75
    /// Groups sent to the reranker.
    static let rerankDepth = 30
    /// Longest "forget" the model may trigger in one request (one day).
    static let maxForgetMinutes = 24 * 60

    init(store: MemoryStore, ai: NemotronClient) {
        self.store = store
        self.ai = ai
    }

    /// What a question needs before the answer call; no side effects (nothing is remembered,
    /// captured or deleted), so it may run on words the user has not finished saying.
    struct Retrieval: Sendable {
        var groups: [MemoryHit] = []
        /// What the model decided this turn needs (nil: no decision, answer from memory).
        var decision: TurnTools.Decision?
        var trace: [String] = []
        /// The place the search was limited to, and how many records were made there.
        var place: (area: MemoryArea, records: Int, ids: Set<Int64>)?
        /// The words the memory was searched with.
        var query: String?
        /// Places the map shows around the user (a question about the surroundings).
        var nearby: [String] = []
        /// The model asked to look and the glasses sent no picture.
        var noLiveView = false
        /// What the model looked up before it decided (the results as it read them).
        var lookedUp = ""
    }
    private var prepared: (question: String, at: Date, task: Task<Retrieval, Never>)?

    /// The user paused: start the turn decision + search + rerank on what was heard so far. If these are
    /// still the words when listening ends, `ask` continues from here instead of starting over
    /// (the wait for the end of speech and the search overlap). Other words: dropped.
    /// Where the user is now (street, area, floor, coordinates), as text for the model.
    private var position: String?

    func prepare(_ question: String, location: LocationFix?, position: String? = nil) {
        self.position = position
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prepared?.question != trimmed else { return }
        prepared?.task.cancel()
        let now = Date()
        prepared = (trimmed, now, Task { await self.retrieve(trimmed, location: location, now: now) })
    }

    func dropPrepared() {
        prepared?.task.cancel()
        prepared = nil
    }

    private func retrieve(_ trimmed: String, location: LocationFix?, now: Date) async -> Retrieval {
        var out = Retrieval()
        let ai = self.ai
        // The turn decision (reply directly, look, search, a command), in parallel with the
        // memory search: by the time the model has asked for the memory, it is usually there.
        await loadDialogIfNeeded()
        let recent = conversation.filter { now.timeIntervalSince($0.at) < 15 * 60 }.suffix(4)
        let talk = await dialogLines(now: now)
        let looked = recent.last?.looked == true ? lastLive.map { Int(now.timeIntervalSince($0.at)) }.flatMap { $0 < 90 ? $0 : nil } : nil
        let safetyBridge = safety
        let hasKey = await ai.hasKey
        let place = position
        let camera = cameraLive
        let box = toolbox
        let decideTask = Task { () -> (decision: TurnTools.Decision?, ms: Int, looked: AgentLoop.Outcome?) in
            guard hasKey else { return (nil, 0, nil) }
            let safetyText = await safetyBridge?.context() ?? ""
            return await Self.decide(ai, user: TurnTools.user(question: trimmed, now: now, conversation: Array(talk),
                                                              safety: safetyText, lookedSecondsAgo: looked, position: place,
                                                              cameraLive: await camera?()), toolbox: box)
        }
        let findTask = Task { await self.find(trimmed, location: location) }
        // A first message is complete by itself: its rerank starts at once. In a conversation
        // the model's own query may say more ("it" resolved), so the rerank waits ~0.2 s for it
        // (one rerank per question: two at once took twice as long each on the 68-question set).
        let searchTask: Task<(groups: [MemoryHit], trace: [String]), Never>? = recent.isEmpty ? Task {
            let found = await findTask.value
            return await self.reranked(found, query: trimmed, location: location)
        } : nil
        let (decision, decideMs, loop) = await withTaskCancellationHandler { await decideTask.value } onCancel: {
            decideTask.cancel()
            findTask.cancel()
            searchTask?.cancel()
        }
        out.decision = decision
        if let loop, !loop.lookedUp.isEmpty {
            out.lookedUp = loop.shown
            out.trace.append("looked up: " + loop.lookedUp.joined(separator: ", "))
        }
        switch decision {
        case .reply: out.trace.append("turn: reply \(decideMs) ms")
        case .look: out.trace.append("turn: tool look_now \(decideMs) ms")
        case .search(let query, let from, let to, let place):
            out.trace.append("turn: tool search_memory \(decideMs) ms" + (query.map { " “\($0.prefix(60))”" } ?? "")
                             + (from != nil || to != nil ? " span \(from.map(Cue.stamp) ?? "…")–\(to.map(Cue.stamp) ?? "now")" : "")
                             + (place.map { " place “\($0)”" } ?? ""))
        case .forget: out.trace.append("turn: tool forget_recent \(decideMs) ms")
        case .command(_, _, let tool), .agent(_, _, let tool): out.trace.append("turn: tool \(tool) \(decideMs) ms")
        case nil: out.trace.append("turn: no decision \(decideMs) ms")
        }
        switch decision {
        case .reply, .forget, .command, .agent:
            findTask.cancel()     // nothing to look up
            searchTask?.cancel()
            return out
        case .look:
            // The glasses frame is the evidence: memory comes along as found, without waiting
            // for the reranker (0.4–3.8 s on the eval).
            searchTask?.cancel()
            let found = await findTask.value
            out.groups = found.groups
            out.trace += found.trace + ["rerank skipped (look)"]
            return out
        case .search, nil:
            break
        }
        // The user named a span of time: the search is done again inside it (what was started
        // before the model said so looked at everything).
        if case .search(let own, let from, let to, let place) = decision, from != nil || to != nil || place != nil, !Task.isCancelled {
            searchTask?.cancel()
            findTask.cancel()
            await narrowed(&out, query: own ?? trimmed, from: from, to: to, place: place, location: location)
            return out
        }
        out.query = trimmed
        if let searchTask {
            let found = await withTaskCancellationHandler { await searchTask.value } onCancel: { searchTask.cancel() }
            out.groups = found.groups
            out.trace += found.trace
            return out
        }
        // In a conversation: a follow-up ("and the phone number?") finds little by its own
        // words, so what the model's self-contained query finds is added, and the reranker
        // judges all of it against that query.
        var found = await findTask.value
        var query = trimmed
        if case .search(let own?, _, _, _) = decision, own.caseInsensitiveCompare(trimmed) != .orderedSame, !Task.isCancelled {
            let second = await find(own, location: location)
            found = (Self.interleave(second.groups, found.groups), found.trace + second.trace.map { "query: " + $0 })
            query = own
            out.query = own
        }
        let ranked = await reranked(found, query: query, location: location)
        out.groups = ranked.groups
        out.trace += ranked.trace
        return out
    }

    /// A search inside what the user named: a span of time, a place, or both. A place that is
    /// known and holds no record leaves the result empty (the answer is "nothing seen there",
    /// not the nearest thing seen elsewhere); a place nobody can locate is searched by its name.
    private func narrowed(_ out: inout Retrieval, query: String, from: Date?, to: Date?, place: String?, location: LocationFix?) async {
        var within: MemoryArea?
        if let place {
            let began = ContinuousClock.now
            within = await area(named: place, here: location)
            if let within {
                let made = await store.ids(within: within)
                let count = made.count
                out.place = (within, count, Set(made))
                out.trace.append("place “\(place)” r \(Int(within.radius)) m: \(count) records · \((ContinuousClock.now - began).milliseconds) ms")
            } else {
                out.trace.append("place “\(place)” not located")
            }
        }
        // The place is the filter now: in the words searched for it only pulls towards records
        // whose text happens to carry the name.
        var query = query
        if let place, within != nil, let range = query.range(of: place, options: [.caseInsensitive, .diacriticInsensitive]) {
            let rest = query.replacingCharacters(in: range, with: " ").split(separator: " ").joined(separator: " ")
            if rest.count >= 3 { query = rest }
        }
        out.query = query
        // About the surroundings: what the map shows around here is fetched alongside.
        var mapTask: Task<[String], Never>?
        if place?.caseInsensitiveCompare("here") == .orderedSame, let location, let nearbyPlaces {
            let words = query
            mapTask = Task { await withTimeout(seconds: 1.5) { await nearbyPlaces(words, location) } ?? [] }
        }
        defer { mapTask?.cancel() }
        let ranked = await reranked(await find(query, location: location, from: from, to: to, within: within), query: query, location: location)
        if let mapTask {
            out.nearby = await mapTask.value
            if !out.nearby.isEmpty { out.trace.append("map: \(out.nearby.count) places nearby") }
        }
        out.groups = ranked.groups
        out.trace += ranked.trace
    }

    /// The second round of a question the first search could not answer: the model picks
    /// other words (or gives up), and the memory is searched once more.
    private func again(_ question: String, first: Retrieval, conversation: [String], location: LocationFix?, now: Date) async -> Retrieval? {
        let ai = self.ai
        var span: (from: Date?, to: Date?) = (nil, nil)
        if case .search(_, let from, let to, _) = first.decision { span = (from, to) }
        let firstText = (first.query ?? question)
            + (first.place.map { " (only in \($0.area.name))" } ?? "")
            + (span.from != nil || span.to != nil ? " (only \(span.from.map(Cue.stamp) ?? "…")–\(span.to.map(Cue.stamp) ?? "now"))" : "")
        let user = TurnTools.againUser(question: question, now: now, position: position, conversation: conversation, first: firstText,
                                       found: first.groups.prefix(6).map { hit in
                                           "- " + ([hit.record.kind, hit.record.name].compactMap { $0 }.joined(separator: " ")
                                                   .nonEmpty ?? String(hit.record.ocrText.prefix(40)))
                                       })
        let began = ContinuousClock.now
        let outcome = await hedged(ai, seconds: 4) { host in
            try await ai.chatTools(system: TurnTools.againSystem, user: user, tools: TurnTools.againTools, route: host)
        }
        guard let turn = try? outcome.result.get(), turn.calls.contains(where: { $0.name == "search_memory" }),
              case .search(let query?, let from, let to, let place) = TurnTools.decision(from: turn),
              query.caseInsensitiveCompare(first.query ?? question) != .orderedSame else { return nil }
        var out = Retrieval()
        // What the user named stays, whatever the model sent this time.
        let keptFrom = span.from ?? from, keptTo = span.to ?? to
        var keptPlace = place
        if case .search(_, _, _, let named?) = first.decision { keptPlace = named }
        out.decision = .search(query, from: keptFrom, to: keptTo, place: keptPlace)
        out.trace = ["second search \((ContinuousClock.now - began).milliseconds) ms “\(query.prefix(60))”"]
        await narrowed(&out, query: query, from: keptFrom, to: keptTo, place: keptPlace, location: location)
        // Nothing new came up: the first answer stands.
        let seen = Set(first.groups.prefix(Self.answerContext).flatMap(\.allRecords).map(\.id))
        guard out.groups.prefix(Self.answerContext).contains(where: { !$0.allRecords.contains { seen.contains($0.id) } }) else { return nil }
        return out
    }

    /// Query vector → search on the phone → one entry per sign/object.
    private func find(_ text: String, location: LocationFix?, from: Date? = nil, to: Date? = nil,
                      within: MemoryArea? = nil) async -> (groups: [MemoryHit], trace: [String]) {
        var trace: [String] = []
        let ai = self.ai
        // 1. Query vector (~0.3–0.9 s; skipped when embeddings are off or slow).
        let (embedding, embedMs) = await Self.queryVector(ai, question: text)
        trace.append(embedding == nil ? "no vector" : "vector \(embedMs) ms")
        // 2. Retrieve on the phone.
        let searchStarted = ContinuousClock.now
        var search = MemorySearch()
        search.keywords = [text]
        search.limit = 60
        search.embedding = embedding
        search.from = from
        search.to = to
        search.within = within
        // Same venue as the user is in now: what was seen here weighs more.
        if let location {
            search.here = MemoryArea(name: "here", latitude: location.latitude, longitude: location.longitude, radius: MemoryArea.venueRadius)
        }
        let hits = await store.search(search)
        // 3. One entry per sign/object: repeated and partial reads collapse into one group.
        let groups = Self.group(hits).map { Self.withDistance($0, from: location) }
        trace.append("search \((ContinuousClock.now - searchStarted).milliseconds) ms · \(hits.count) records → \(groups.count) groups")
        return (groups, trace)
    }

    /// 4. Cross-encoder rerank of the top groups. Slow (> 3 s) or failed: the fused order stays.
    private func reranked(_ found: (groups: [MemoryHit], trace: [String]), query text: String,
                          location: LocationFix? = nil) async -> (groups: [MemoryHit], trace: [String]) {
        var (groups, trace) = found
        let ai = self.ai
        guard !groups.isEmpty, await ai.rerankEnabled, !Task.isCancelled else { return (groups, trace) }
        let head = Array(groups.prefix(Self.rerankDepth))
        let passages = head.map(Self.passage)
        let rerankStarted = ContinuousClock.now
        if let logits = await withTimeout(seconds: 3, { try await ai.rerank(query: text, passages: passages) }),
           logits.count == head.count {
            var reranked = zip(head, logits).map { hit, logit -> MemoryHit in
                var hit = hit
                hit.signals.rerankLogit = logit
                return hit
            }
            // Seen in the venue the user is in now: counts for a little more than the same match elsewhere.
            func weight(_ hit: MemoryHit) -> Double {
                (hit.signals.rerankLogit ?? -.infinity) + ((hit.distanceMeters ?? .infinity) <= MemoryArea.venueRadius ? Self.sameVenueBonus : 0)
            }
            reranked.sort { weight($0) > weight($1) }
            groups = reranked + groups.dropFirst(head.count)
            trace.append("rerank \((ContinuousClock.now - rerankStarted).milliseconds) ms (\(await ai.rerankModelName.split(separator: "/").last ?? ""))")
        } else {
            trace.append("no rerank")
        }
        return (groups, trace)
    }

    /// Two result lists as one, taking turns (both lists' best stay near the top), each record once.
    private static func interleave(_ a: [MemoryHit], _ b: [MemoryHit]) -> [MemoryHit] {
        var seen = Set<Int64>()
        var out: [MemoryHit] = []
        for i in 0..<max(a.count, b.count) {
            for list in [a, b] where i < list.count {
                let ids = list[i].allRecords.map(\.id)
                guard !ids.contains(where: seen.contains) else { continue }
                seen.formUnion(ids)
                out.append(list[i])
            }
        }
        return out
    }

    /// The turn call with native tool calling, raced over both hosts.
    private static func decide(_ ai: NemotronClient, user: String, toolbox: ReadToolbox? = nil) async -> (decision: TurnTools.Decision?, ms: Int, looked: AgentLoop.Outcome?) {
        let began = ContinuousClock.now
        // The agent loop: the model may look things up first (earlier conversation, the state
        // of a thing, the log, the map), then ends in one of the turn's own tools.
        let outcome = await hedged(ai, seconds: 8) { host in
            try await AgentLoop.run(ai, system: TurnTools.system, user: user, decide: TurnTools.tools, reads: AgentLoop.turnReads,
                                    toolbox: toolbox, route: host)
        }
        if case .failure(let error) = outcome.result {
            Log.net.info("turn call failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, privacy: .public)")
        }
        let loop = try? outcome.result.get()
        return (loop.map { TurnTools.decision(from: $0.reply) }, (ContinuousClock.now - began).milliseconds, loop)
    }

    func ask(_ question: String, location: LocationFix?, position: String? = nil, now: Date = Date()) async -> AskResult {
        self.position = position
        let ai = self.ai
        await ai.beginQuestion()
        defer { Task { await ai.endQuestion() } }
        return await run(question, location: location, now: now, started: ContinuousClock.now, second: nil, trace: Trace())
    }

    /// One pass over a question. `second`: the retrieval of the second search round, when the
    /// first pass found nothing that answers (at most one such round).
    private func run(_ question: String, location: LocationFix?, now: Date, started: ContinuousClock.Instant,
                     second: Retrieval?, trace earlier: Trace) async -> AskResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var trace = earlier
        rankedForResult = []
        lookedLive = false
        let ai = self.ai
        // Safety status/log (local, fast) is fetched while the question is embedded.
        let safetyBridge = safety
        async let safetyTextAsync = safetyBridge?.context() ?? ""
        // Follow-ups: the last few turns, and the live frame of a look that just happened.
        await loadDialogIfNeeded()
        let turns = Array(conversation.filter { now.timeIntervalSince($0.at) < 15 * 60 }.suffix(4))
        let talkLines = await dialogLines(now: now)
        let carried = turns.last?.looked == true ? lastLive.flatMap { now.timeIntervalSince($0.at) < 90 ? $0 : nil } : nil

        // 1–4. Turn decision + query vector + search + rerank. Already running if the same
        // words were heard a moment ago while the user was still finishing (`prepare`).
        let retrieval: Retrieval
        if let second {
            retrieval = second
        } else if let ready = prepared, ready.question == trimmed, now.timeIntervalSince(ready.at) < 20 {
            retrieval = await ready.task.value
            trace.add("prepared while listening")
        } else {
            prepared?.task.cancel()
            retrieval = await retrieve(trimmed, location: location, now: now)
        }
        prepared = nil
        retrieval.trace.forEach { trace.add($0) }
        let groups = retrieval.groups
        switch retrieval.decision {
        case .reply: lastTool = "say"
        case .look: lastTool = "look_now"
        case .search: lastTool = "search_memory"
        case .forget: lastTool = "forget_recent"
        case .command(_, _, let tool), .agent(_, _, let tool): lastTool = tool
        case nil: lastTool = nil
        }
        let isLook: Bool
        switch retrieval.decision {
        case .reply(let text):
            // Conversation that is not about something seen: the model's own words, no evidence check.
            trace.add("chat")
            var r = result(trimmed, text, .seen, [], true, started, nil,
                           (Self.detectLanguage(text) ?? Self.detectLanguage(trimmed))?.code, trace)
            r.isCommand = true
            // The reply ends by asking the user something: listen for the answer.
            r.expectsReply = text.last.map { $0 == "?" || $0 == "？" } ?? false
            return r
        case .forget(let minutes, let reply):
            let language = (Self.detectLanguage(reply) ?? Self.detectLanguage(trimmed))?.code
            guard let minutes, (1...Self.maxForgetMinutes).contains(minutes) else {
                trace.add("forget: invalid span (\(minutes.map(String.init) ?? "-"))")
                return result(trimmed, Self.unclearText, .unknown, [], true, started, nil, language, trace)
            }
            let removed = await store.delete(since: now.addingTimeInterval(-Double(minutes) * 60))
            _ = await dialogWrites?.value
            await dialog.delete(since: now.addingTimeInterval(-Double(minutes) * 60))
            await safetyBridge?.forget(now.addingTimeInterval(-Double(minutes) * 60))
            trace.add("forget: \(minutes) min, \(removed) records deleted")
            var r = result(trimmed, reply, .seen, [], true, started, nil, language, trace)
            r.isCommand = true
            return r
        case .command(let command, let reply, let tool):
            // Muisti Turva commands: the reply is an acknowledgement / read-back, run by the caller.
            trace.add("safety: \(tool)")
            var r = result(trimmed, reply, .seen, [], true, started, nil,
                           (Self.detectLanguage(reply) ?? Self.detectLanguage(trimmed))?.code, trace)
            r.safety = command
            r.isCommand = true
            return r
        case .agent(let command, let reply, let tool):
            // An intent, a destination, a place, a mute: kept by the agent, run by the caller.
            trace.add("agent: \(tool)")
            var r = result(trimmed, reply, .seen, [], true, started, nil,
                           (Self.detectLanguage(reply) ?? Self.detectLanguage(trimmed))?.code, trace)
            r.agent = command
            r.isCommand = true
            r.expectsReply = reply.last.map { $0 == "?" || $0 == "？" } ?? false
            return r
        case .look:
            isLook = true
        case .search, nil:
            isLook = false
        }
        // The model asked to look: the glasses frame is taken now, while the context is built.
        var liveTask: Task<(live: (jpeg: Data, ocr: String, at: Date)?, ms: Int), Never>?
        if isLook, let provider = liveView {
            liveTask = Task {
                let began = ContinuousClock.now
                let live = await provider()
                return (live, (ContinuousClock.now - began).milliseconds)
            }
        }
        var context = Array(groups.prefix(Self.answerContext))
        rankedForResult = groups.prefix(Self.rerankDepth).map { $0.allRecords.map(\.id) }
        // Follow-ups: the records the previous reply relied on stay in view ("what was next to
        // it?" retrieves nothing about "it" by itself).
        // A question about one place: nothing made elsewhere comes along (not the previous
        // answer's records, not the newest frames, not the latest episode).
        let placeIDs = retrieval.place?.ids
        let carriedIDs = (turns.last?.ids ?? []).filter { placeIDs?.contains($0) ?? true }
        if !carriedIDs.isEmpty {
            let present = Set(context.flatMap(\.allRecords).map(\.id))
            let missing = carriedIDs.filter { !present.contains($0) }
            let carried = await store.records(missing).map { MemoryHit(record: $0, score: 0) }
            context += Self.group(carried).map { Self.withDistance($0, from: location) }
            if !missing.isEmpty { trace.add("carried \(missing.count) from the previous answer") }
        }
        if !context.isEmpty { trace.add("top: " + context.prefix(3).map(Self.traceLabel).joined(separator: ", ")) }

        // 5. One model call: understand the question and answer from the records only.
        guard await ai.hasKey else {
            return offline(trimmed, context, started, note: String(localized: "No Nemotron key; local search."), trace)
        }
        // Episodes of the best records: the frames seen just before and after them, in order,
        // so the model can answer "what was next to / after / on the same walk as X".
        var episodeIDs: [Int64] = []
        for id in context.prefix(5).compactMap(\.record.episodeID) where !episodeIDs.contains(id) { episodeIDs.append(id) }
        episodeIDs = Array(episodeIDs.prefix(Self.episodeContext))
        // The previous answer's episode, for follow-ups about what was around it.
        for id in context.filter({ $0.allRecords.contains { carriedIDs.contains($0.id) } }).compactMap(\.record.episodeID)
            where !episodeIDs.contains(id) && episodeIDs.count < Self.episodeContext + 1 { episodeIDs.append(id) }
        // The most recent episode is always there: "what did I just see / where am I now" need
        // the latest frames whatever the search ranked first.
        if placeIDs == nil, let latest = await store.episodes(limit: 1).first, !episodeIDs.contains(latest.id) {
            episodeIDs.append(latest.id)
        }
        let episodes = await store.episodes(episodeIDs)
        var episodeText: [String] = []
        var pool = context
        var position: [Int64: (index: Int, count: Int)] = [:]
        for id in episodeIDs {
            guard let episode = episodes.first(where: { $0.id == id }) else { continue }
            let frames = await store.records(inEpisode: id)
            for (i, r) in frames.enumerated() { position[r.id] = (i + 1, frames.count) }
            let anchors = Set(context.flatMap(\.allRecords).map(\.id))
            let shown = frames.contains(where: { anchors.contains($0.id) })
                ? Self.window(frames, around: anchors)
                : Array(frames.suffix(Self.framesPerEpisode))   // latest episode: its last frames
            episodeText.append(Self.describe(episode, frames: shown, total: frames.count, now: now,
                                             position: { position[$0]?.index }))
            let known = Set(pool.flatMap(\.allRecords).map(\.id))
            pool += shown.filter { !known.contains($0.id) }.map { MemoryHit(record: $0, score: 0) }
        }
        if !episodeText.isEmpty { trace.add("\(episodeText.count) episodes") }
        // Reads of the same sign are checked together (a cited partial read is backed by the
        // full read of the same sign).
        pool = Self.group(pool)

        let answerStarted = ContinuousClock.now
        let language = Self.detectLanguage(trimmed)
        // Newest frames first, so recency never has to be worked out from relevance order.
        let latest = await store.recent(limit: 5).filter { placeIDs?.contains($0.id) ?? true }.map { r -> String in
            let ago = max(0, Int(now.timeIntervalSince(r.seenAt) / 60))
            let what = [r.kind, r.name].compactMap { $0 }.joined(separator: " ")
            return "- id \(r.id), minutes_ago: \(ago), \(Self.promptTime(r.seenAt))" + (what.isEmpty ? "" : ", \(what)")
                + (r.street.map { ", \($0)" } ?? "")
        }
        var safetyText = await safetyTextAsync
        // The frames of the first records, as one picture: the model looks at them as well as
        // reading their text (colours, layout, what the OCR missed).
        // The newest frame is always one of them: "what am I looking at", "this is my medicine".
        var pictureRecords = Array(context.prefix(4).map(\.record))
        // The keyframe channel's best match is shown too, even when the text reranker put it
        // lower: what it found may be in the picture only, not in any text the reranker reads.
        var extras: [MemoryRecord] = []
        if let pictured = context.filter({ ($0.signals.imageRank ?? .max) <= 3 })
            .min(by: { ($0.signals.imageRank ?? .max) < ($1.signals.imageRank ?? .max) })?.record,
           !pictureRecords.contains(where: { $0.id == pictured.id }) {
            extras.append(pictured)
        }
        if let newest = await self.store.recent(limit: 1).first, placeIDs?.contains(newest.id) ?? true,
           !pictureRecords.contains(where: { $0.id == newest.id }),
           !extras.contains(where: { $0.id == newest.id }) {
            extras.append(newest)
        }
        pictureRecords = Array(pictureRecords.prefix(4 - extras.count)) + extras
        let store = self.store
        // Right after a look, the live frame stays in view as cell 1 (follow-ups about it); the
        // memory frames fill the rest, so a question about earlier still has them.
        // Right after a look, the picture is only that live frame (a grid mixed it up with memory
        // signs); the records still come as text for questions about earlier.
        let picture: Data?
        let pictureCaption: String?
        if let live = carried, !isLook {
            picture = Self.montage(jpegs: [live.jpeg])
            pictureCaption = "the LIVE VIEW from your last look, \(Int(now.timeIntervalSince(live.at))) s ago (no memory frames this time)"
        } else {
            let recordJPEGs = pictureRecords.compactMap { try? Data(contentsOf: store.frameURL($0)) }
            picture = Self.montage(jpegs: recordJPEGs)
            let newestID = pictureRecords.map(\.id).max()
            let cells = pictureRecords.enumerated().map { cell -> String in
                let ago = Self.agoText(now.timeIntervalSince(cell.element.seenAt))
                return "\(cell.offset + 1) = record id \(cell.element.id), seen \(ago) ago" + (cell.element.id == newestID ? " (newest kept frame)" : "")
            }
            pictureCaption = picture == nil ? nil : "a grid of memory frames (NOT the live view): " + cells.joined(separator: ", ")
                + " (1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right)"
        }
        // The position may be said in the answer (a house number in the street name is not a
        // number read from a sign): it counts as shown to the model for the evidence check.
        let place = self.position
        if let place { safetyText += "\n" + place }
        // What was said in the conversation may be said back (a time the user mentioned is
        // not a number read from a sign): it counts as shown for the evidence check.
        if !talkLines.isEmpty { safetyText += "\n" + talkLines.joined(separator: "\n") }
        var user = MemoryPrompts.answerUser(question: trimmed, language: language, now: now, position: place,
                                            records: context.map { hit in
                                                Self.describe(hit, now: now, position: position[hit.record.id])
                                                    + (retrieval.place.map { "\nMade in: \($0.area.name) (by the phone's position)" } ?? "")
                                            },
                                            episodes: episodeText, latest: latest, safety: safetyText, picture: pictureCaption,
                                            conversation: talkLines)
        if let place = retrieval.place {
            user += "\n\nPlace asked about: \(place.area.name). The search was limited to records made there: "
                + (place.records == 0
                   ? "there are none, the glasses recorded nothing in that place. The whole answer is one sentence saying that you did not see it there (BILMIYORUM, found false, used_ids []). Naming something seen in another place is a mistake here, however similar it is."
                   : "you do have records from there (\(place.records)), so never say you have none. Every record listed under Records was made in \(place.area.name) (the phone's position says so, whatever the record's own text or street says), and only those; frames listed elsewhere in this message may be from other places and do not answer a question about \(place.area.name). If none of them shows what is asked, the whole answer is one sentence saying you did not see it there.")
        }
        if !retrieval.lookedUp.isEmpty {
            user += "\n\nWhat you looked up before answering (it counts as known to you; say where it comes from — the log, the map, what the user said):" + retrieval.lookedUp
            safetyText += retrieval.lookedUp
        }
        if retrieval.noLiveView {
            user += "\n\nNO LIVE VIEW: you wanted to look through the glasses, but their camera is not sending pictures right now. "
                + "If the records, the position or the map results answer the question (what is around here, what was seen earlier), answer from them. "
                + "If it can only be answered by looking (what is this, read this), say in one short sentence that the glasses' camera is not sending pictures right now."
        }
        if !retrieval.nearby.isEmpty {
            user += "\n\nMap results near the user's position now (from Apple Maps, NOT seen by the glasses; nearest first):\n" + retrieval.nearby.joined(separator: "\n")
                + "\nWhen the user asks what is nearby or around here and the records do not show it, you may name up to three of these, saying plainly that the map shows them and that you have not seen them (label BILMIYORUM, found false: this is the one case where a not-seen answer says more than one sentence). Distances as written."
            safetyText += "\n" + retrieval.nearby.joined(separator: "\n")
        }
        var image = picture.map { NemotronClient.ImagePart(jpeg: $0) }
        // Follow-up right after a look ("what does it say exactly?", "is it on?"): the same live
        // frame stays in view, as it would for a person still looking at it.
        if let live = carried, !isLook {
            let age = Int(now.timeIntervalSince(live.at))
            user += "\n\nLIVE VIEW (from your last look, \(age) seconds ago; it is the attached picture): text read on it by "
                + "the phone: \(live.ocr.isEmpty ? "(none)" : live.ocr). Right after a look, \"it\", \"this\", \"the sign\", \"there\" "
                + "mean what this picture shows, not a memory record. If the user is still talking about what they see, answer from "
                + "it; what you see in it counts as seen. Something shown on a TV, screen, poster or packaging picture is not the real "
                + "thing: say so. For questions about earlier, use the records as usual."
            safetyText += "\n" + live.ocr + "\n" + Self.promptTime(live.at)
            lookedLive = true
            trace.add("live view (carried)")
        }
        #if DEBUG
        // Last prompt, for checking retrieval/episode context (Documents/last_prompt.txt).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? user.write(to: docs.appendingPathComponent("last_prompt.txt"), atomically: true, encoding: .utf8)
        }
        #endif
        // Routed to "look" (and not already looking at a carried frame): take the live frame
        // first, so the answer call sees it right away.
        if isLook {
            // A look asked for is a fresh frame; the last one (≤ 30 s old) only if no frame comes.
            let taken = await liveTask?.value
            if let taken { trace.add("live frame \(taken.live == nil ? "none" : "\(taken.ms) ms")") }
            if let fresh = taken?.live { lastLive = fresh }
            let cached = taken?.live == nil ? lastLive.flatMap { Date().timeIntervalSince($0.at) < 30 ? $0 : nil } : nil
            guard let live = taken?.live ?? cached else {
                // No picture comes from the glasses: that is told to the model as the result of
                // the look, and the question goes on with what the memory, the position and the
                // map hold (before, a fixed "I can't see anything" ended the turn here, also for
                // "is there a café nearby", and came back on every rephrasing).
                trace.add("look_now: no live frame → memory")
                var blind = retrieval
                blind.decision = .search(retrieval.query ?? trimmed, place: nil)
                blind.noLiveView = true
                if blind.nearby.isEmpty, let location, let nearbyPlaces {
                    blind.nearby = await withTimeout(seconds: 1.5) { await nearbyPlaces(trimmed, location) } ?? []
                }
                return await run(question, location: location, now: now, started: started, second: blind, trace: trace)
            }
            trace.add(cached == nil ? "look_now" : "look_now (reused frame)")
            lookedLive = true
            let when = Self.promptTime(live.at)
            let age = Int(Date().timeIntervalSince(live.at))
            user += "\n\nLIVE VIEW (just taken for this question): the attached picture was taken \(age < 10 ? "just now" : "\(age) seconds ago"), "
                + "\(when), by the glasses (it replaces the memory grid). Text read on it by the phone: \(live.ocr.isEmpty ? "(none)" : live.ocr). "
                + "Answer the question from this picture, saying first what it shows; then, if it helps, what the safety log or "
                + "memory adds. What you see in it counts as seen (found true, label GORDUM when it answers). "
                + "Something shown on a TV, screen, poster or packaging picture is not the real thing: say what it is shown on "
                + "(a flame on a TV does not mean a stove here is on)."
            image = NemotronClient.ImagePart(jpeg: live.jpeg)
            safetyText += "\n" + live.ocr + "\n" + when
        }
        var thinking = false
        if case .look(let reasoning) = retrieval.decision, lookedLive, (Self.thinkingForWorkedAnswers && reasoning) || EvalSwitch.thinkLook {
            thinking = true
            trace.add("thinking on")
        }
        var answered = await Self.answer(ai, user: user, image: image, looking: lookedLive, thinking: thinking, trace: &trace)
        if case .failure = answered, image != nil {
            // A host that refuses the picture must not cost the answer: once more, text only.
            trace.add("retry without picture")
            answered = await Self.answer(ai, user: user, image: nil, looking: lookedLive, trace: &trace)
        }
        var draft: AnswerDraft
        switch answered {
        case .success(let value):
            draft = value
        case .failure(let error):
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.net.error("answer call failed: \(why, privacy: .public)")
            return offline(trimmed, context, started, note: String(localized: "Nemotron didn't answer (\(why)); local search."), trace)
        }
        trace.add("answer \((ContinuousClock.now - answerStarted).milliseconds) ms\(image == nil ? "" : " · picture")")

        // Looked, and what was asked about is too small to read in the stream's frame (a
        // problem on a laptop across the table): one full-resolution photo from the glasses,
        // and the same question again from it. Still unreadable: the model's own sentence
        // asking for a closer look stands.
        if isLook, lookedLive, draft.too_small == true, let sharpView, !Task.isCancelled {
            let began = ContinuousClock.now
            if let sharp = await withTimeout(seconds: 6, { await sharpView() }) ?? nil {
                trace.add("sharper photo \((ContinuousClock.now - began).milliseconds) ms")
                lastLive = sharp
                let closer = user + "\n\nA SHARPER PHOTO of the same view was just taken for this question and is the attached picture now (full resolution). "
                    + "Text read on it by the phone: \(sharp.ocr.isEmpty ? "(none)" : sharp.ocr). Answer the question from it."
                safetyText += "\n" + sharp.ocr
                image = NemotronClient.ImagePart(jpeg: sharp.jpeg)
                if case .success(let second) = await Self.answer(ai, user: closer, image: image, looking: true, thinking: thinking, trace: &trace) {
                    draft = second
                    user = closer
                }
            } else {
                trace.add("sharper photo: none")
            }
        }

        // One repair round: tell the model exactly which check failed and let it answer again.
        var final = draft
        if final.action == .answer, let why = Self.rejection(final, hits: pool, extra: safetyText, liveLook: lookedLive && (final.used_ids ?? []).isEmpty) {
            Log.pipeline.info("evidence check failed (\(why, privacy: .public)); asking again")
            let retry = user + "\n\nYour previous reply was rejected by the evidence check: \(why). " +
                "Answer again following the rules: leave out anything you cannot copy from the records' text. " +
                "A figure you worked out yourself from what was read (a sum, a product, a solution) is kept: mark it worked_out in figures."
            if case .success(let second) = await Self.answer(ai, user: retry, image: image, looking: lookedLive, trace: &trace) {
                final = second
                trace.add("repair round")
            }
        }

        // Second look: the model said "not seen" although the reranker found the top record very
        // relevant. One more call with that fact; the evidence checks still apply after it.
        let refused = final.action == .answer
            && (AnswerLabel(rawValue: final.label.uppercased()) != .seen || final.found == false)
        if refused, let top = context.first?.signals.rerankLogit, top >= Self.secondLookLogit {
            let retry = user + "\n\nSecond look: search ranked record id \(context[0].record.id) as highly relevant to this question. " +
                "Re-read it and its episode. If it answers the question, even in other words, from a sign, plaque or advertisement, " +
                "or from the order of frames in its episode, give that answer with found true and label GORDUM. " +
                "If it really does not, keep BILMIYORUM."
            if case .success(let second) = await Self.answer(ai, user: retry, image: image, looking: lookedLive, trace: &trace),
               AnswerLabel(rawValue: second.label.uppercased()) == .seen, second.found != false,
               Self.rejection(second, hits: pool, extra: safetyText, liveLook: lookedLive && (second.used_ids ?? []).isEmpty) == nil {
                final = second
                trace.add("second look")
            }
        }
        // Still not found: one more search with other words, if the model sees a way to ask.
        // (Not for a place that holds no records at all: other words find nothing there either.)
        let notFound = final.action == .answer
            && (AnswerLabel(rawValue: final.label.uppercased()) != .seen || final.found == false)
        if notFound, second == nil, !isLook, !lookedLive, retrieval.place?.records != 0, retrieval.nearby.isEmpty, !EvalSwitch.noSecondSearch, !Task.isCancelled,
           let next = await again(trimmed, first: retrieval, conversation: talkLines,
                                  location: location, now: now) {
            next.trace.forEach { trace.add($0) }
            var nextRound = next
            nextRound.trace = []
            return await run(question, location: location, now: now, started: started, second: nextRound, trace: trace)
        } else if notFound, second == nil, !isLook, !lookedLive, retrieval.place?.records != 0, !EvalSwitch.noSecondSearch {
            trace.add("second search: nothing new")
        }
        if let doubted = await lookAgain(final, question: trimmed, hits: pool, trace: &trace) { final = doubted }
        // "Did I lock it?": the frames of the log entry the answer rests on are looked at once
        // more, in order, before a "yes" is said; they are shown with the answer as its proof.
        var eventFrames: [URL] = []
        if let ids = final.event_ids, !ids.isEmpty {
            eventFrames = await safetyBridge?.frames(ids) ?? []
            if let honest = await doneCheck(final, question: trimmed, frames: eventFrames, trace: &trace) { final = honest }
        }
        var answer = checked(final, question: trimmed, hits: pool, started: started, trace: trace, extra: safetyText)
        answer.safetyFrames = eventFrames
        answer.expectsReply = final.expects_reply == true
        if lookedLive { answer.liveFrame = lastLive?.jpeg }
        return answer
    }

    /// Visual re-check (Ömer's `look_again`, v6): an answer that rests on something seen, not
    /// on text read from the frame (no quote is in the cited records' OCR), is checked once more
    /// against its best frame at full size with a narrow yes/no question. Vision-model object
    /// lists hallucinate now and then (an "aquarium" for a playground net, an elevator next to a
    /// directory); a claim no frame confirms becomes "I don't know". Slow or failed: keep the answer.
    private func lookAgain(_ draft: AnswerDraft, question: String, hits: [MemoryHit], trace: inout Trace) async -> AnswerDraft? {
        if EvalSwitch.noLookAgain { return nil }
        guard draft.action == .answer, !lookedLive, AnswerLabel(rawValue: draft.label.uppercased()) == .seen,
              draft.found != false, !(draft.used_ids ?? []).isEmpty else { return nil }
        let evidence = Self.evidence(for: draft, in: hits)
        let ocr = evidence.map(Self.mergedOCR).joined(separator: "\n")
        let readFromText = draft.quotes.contains { !$0.hasPrefix("(") && EvidenceRule.quoteSupported($0, in: ocr) }
            || !EvidenceRule.numberRuns(draft.answer).isEmpty
        // "Seen", although the search itself found nothing it thought relevant among what the
        // answer cites: looked at again whatever the quotes say (a true quote of a place name
        // carried a made-up "zebras at the museum" past this check on 14 Nov).
        let best = evidence.compactMap(\.signals.rerankLogit).max()
        let unsupported = (best ?? -.infinity) < Self.unsupportedLogit
        guard !readFromText || unsupported else { return nil }
        // Every frame the answer cites, not just the first: "what came right after the pharmacy"
        // cites the pharmacy and the thing after it, and only one of the two photos shows the
        // thing claimed. (With the first photo alone, such answers were withdrawn as soon as the
        // check became fast enough to always finish: 4 of 68 on 14 Nov.)
        let used = Set(draft.used_ids ?? [])
        var cited = evidence.flatMap(\.allRecords).filter { used.contains($0.id) }
        if cited.isEmpty, let first = evidence.first?.record { cited = [first] }
        let frames = cited.prefix(4).compactMap { try? Data(contentsOf: store.frameURL($0)) }
        guard let record = cited.first, let jpeg = frames.count == 1 ? frames[0] : Self.montage(jpegs: frames) else { return nil }
        let ai = ai
        let user = "Question: \(question)\nClaim: \(draft.answer)"
            + (frames.count > 1 ? "\nThe picture is a sheet of \(frames.count) photos, numbered." : "")
        let began = ContinuousClock.now
        let verdict = try? await hedged(ai, seconds: 3.5, { host in
            try await ai.chatJSON(LookAgain.Verdict.self, system: LookAgain.system, user: user,
                                  image: NemotronClient.ImagePart(jpeg: jpeg), jsonSchema: LookAgain.schema,
                                  schemaName: "look_again", maxTokens: 120, temperature: 0, route: host)
        }).result.get()
        guard let verdict else {
            trace.add("look again: no verdict")
            return nil
        }
        trace.add("look again #\(record.id): \(verdict.confirmed ? "confirmed" : "not confirmed") \((ContinuousClock.now - began).milliseconds) ms")
        Log.pipeline.info("look again #\(record.id): \(verdict.confirmed) · \(verdict.seen, privacy: .public)")
        guard !verdict.confirmed else { return nil }
        var doubted = draft
        doubted.found = false
        doubted.label = AnswerLabel.unknown.rawValue
        doubted.answer = draft.unclear_reply ?? Self.unclearText
        return doubted
    }

    /// An answer that says something was done or is so ("yes, you locked it at 08:14"), resting
    /// on a log entry made from frames: those frames, in time order, are shown to the model with
    /// the answer. When they show the object but not the thing claimed, the answer becomes what
    /// they do show ("I saw you at the door, but not locking it"), labelled not sure. Entries
    /// the user said themselves have no frames and are not checked. Slow or failed: the answer stays.
    private func doneCheck(_ draft: AnswerDraft, question: String, frames: [URL], trace: inout Trace) async -> AnswerDraft? {
        if EvalSwitch.noLookAgain { return nil }
        guard draft.action == .answer, AnswerLabel(rawValue: draft.label.uppercased()) == .seen, draft.found != false else { return nil }
        let jpegs = frames.suffix(8).compactMap { try? Data(contentsOf: $0) }
        let began = ContinuousClock.now
        guard let verdict = await Self.doneVerdict(ai, question: question, answer: draft.answer, jpegs: jpegs) else {
            if !jpegs.isEmpty { trace.add("done check: no verdict") }
            return nil
        }
        trace.add("done check (\(jpegs.count) frames): \(verdict.verdict) \((ContinuousClock.now - began).milliseconds) ms")
        guard verdict.verdict == "not_shown", let reply = verdict.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return nil }
        var honest = draft
        honest.answer = reply
        honest.label = AnswerLabel.unsure.rawValue
        honest.support = .stated
        return honest
    }

    /// The frames of a log entry, in time order, against what an answer says was done.
    static func doneVerdict(_ ai: NemotronClient, question: String, answer: String, jpegs: [Data]) async -> DoneCheck.Verdict? {
        guard let last = jpegs.last else { return nil }
        let several = await ai.multiImageChat && jpegs.count > 1
        let sheet = jpegs.count > 1 ? Self.montage(jpegs: Array(jpegs.suffix(4)), cell: 768) : last
        @Sendable func ask(separate: Bool) async throws -> DoneCheck.Verdict {
            let shown = separate ? jpegs.count : min(jpegs.count, 4)
            let user = "Question: \(question)\nAnswer: \(answer)\n"
                + (shown > 1 ? "The \(shown) photos are in time order, 1 (oldest) to \(shown) (the moment of the log entry)\(separate ? "" : ", numbered on one sheet")." : "One photo: the moment of the log entry.")
            return try await ai.chatJSON(DoneCheck.Verdict.self, system: DoneCheck.system, user: user,
                                         image: .init(jpeg: separate ? last : (sheet ?? last)),
                                         earlierImages: separate ? jpegs.dropLast().map { NemotronClient.ImagePart(jpeg: $0) } : [],
                                         jsonSchema: DoneCheck.schema, schemaName: "done_check", maxTokens: 160, temperature: 0)
        }
        return await withTimeout(seconds: 5) { () -> DoneCheck.Verdict in
            do { return try await ask(separate: several) } catch NemotronClient.NemotronError.http(400, _) where several {
                return try await ask(separate: false)
            }
        }
    }

    /// The answer call, raced over both hosts of the same model (`hedged`): the host that is
    /// fast right now answers; the other joins after a short wait if the first stays silent.
    /// (Before: Verda got 12 s, then NVIDIA build 20 s, one after the other.)
    private static func answer(_ ai: NemotronClient, user: String, image: NemotronClient.ImagePart? = nil, looking: Bool = false,
                               thinking: Bool = false, trace: inout Trace) async -> Result<AnswerDraft, Error> {
        let began = ContinuousClock.now
        // Looking through the glasses now: working something out from the view is allowed, and
        // the schema asks which numbers were read and which were calculated.
        let user = looking ? user + MemoryPrompts.workOutNote : user
        let schema = looking ? MemoryPrompts.lookAnswerSchema : MemoryPrompts.answerSchema
        let outcome = await hedged(ai, seconds: 20) { host in
            let draft = try await Reasoning.$on.withValue(thinking) {
                try await ai.chatJSON(AnswerDraft.self, system: MemoryPrompts.answerSystem, user: user, image: image,
                                      jsonSchema: schema, schemaName: "answer", maxTokens: looking ? 1500 : 1000,
                                      temperature: 0, route: host)
            }
            // A reply with no words ("/") is a failed decode, not an answer: the other host's counts.
            guard draft.answer.contains(where: \.isLetter) else {
                throw NemotronClient.NemotronError.badResponse("empty answer")
            }
            return draft
        }
        let host = outcome.route.map { $0 == .primary ? "primary" : "fallback" } ?? "-"
        trace.add("answer call \((ContinuousClock.now - began).milliseconds) ms (\(host) host)")
        if case .failure(let error) = outcome.result {
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.net.info("answer: no host answered (\(why, privacy: .public))")
        }
        return outcome.result
    }

    /// "40 s", "12 min", "5 h 30 min", "2 days".
    static func agoText(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 90 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        return "\(s / 86_400) days"
    }

    /// Up to four keyframes (already blurred) in a 2×2 grid, numbered 1–4, as one JPEG: one
    /// picture works on every host, several do not.
    /// Long edge of one frame in the answer picture. Measured with Vision OCR on the 73-photo
    /// set: of the words legible in the stored 1536 px keyframe, a 640 px cell kept 47 %,
    /// 896 px 58 %, 1280 px 73 %. 896 px doubles the picture's pixels; check latency in the eval.
    static let pictureCell: CGFloat = EvalSwitch.pictureCell ?? 896

    static func montage(_ urls: [URL], cell: CGFloat = QueryEngine.pictureCell) -> Data? {
        montage(jpegs: urls.compactMap { try? Data(contentsOf: $0) }, cell: cell)
    }

    static func montage(jpegs: [Data], cell: CGFloat = QueryEngine.pictureCell) -> Data? {
        let images = jpegs.prefix(4).compactMap { ImageData.thumbnail($0, maxPixel: Int(cell)) }
        guard !images.isEmpty else { return nil }
        let columns = images.count == 1 ? 1 : 2
        let rows = images.count <= 2 ? 1 : 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: cell * CGFloat(columns), height: cell * CGFloat(rows))
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, image) in images.enumerated() {
                let origin = CGPoint(x: CGFloat(i % columns) * cell, y: CGFloat(i / columns) * cell)
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let scale = min(cell / w, cell / h)
                let rect = CGRect(x: origin.x + (cell - w * scale) / 2, y: origin.y + (cell - h * scale) / 2,
                                  width: w * scale, height: h * scale)
                UIImage(cgImage: image).draw(in: rect)
                let label = NSAttributedString(string: " \(i + 1) ", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 44),
                    .foregroundColor: UIColor.white,
                    .backgroundColor: UIColor.black.withAlphaComponent(0.75),
                ])
                label.draw(at: CGPoint(x: origin.x + 8, y: origin.y + 8))
            }
        }
        return rendered.jpegData(compressionQuality: 0.7)
    }

    /// Language of the question (Apple NaturalLanguage), as an English name for the prompt.
    static func detectLanguage(_ text: String) -> (code: String, name: String)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // Short messages ("naber") are often misread (German): only a confident guess is passed;
        // otherwise the model uses the language of the question and the conversation.
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.8 else { return nil }
        let code = language.rawValue
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        return (code, name)
    }

    private static func queryVector(_ ai: NemotronClient, question: String) async -> ([Float]?, Int) {
        let started = ContinuousClock.now
        guard await ai.embeddingsEnabled else { return (nil, 0) }
        let vector = await withTimeout(seconds: 2) { try await ai.embed(question, as: .query) }
        return (vector, (ContinuousClock.now - started).milliseconds)
    }

    private static func withDistance(_ hit: MemoryHit, from location: LocationFix?) -> MemoryHit {
        guard let location else { return hit }
        var hit = hit
        hit.distanceMeters = hit.allRecords.compactMap { r -> Double? in
            guard let lat = r.latitude, let lon = r.longitude else { return nil }
            return MemoryStore.haversine(location.latitude, location.longitude, lat, lon)
        }.min()
        return hit
    }

    // MARK: Grouping

    /// Collapses reads of the same sign/object (same name or mostly the same words, within
    /// 150 m) into one hit whose `record` is the most complete read.
    static func group(_ hits: [MemoryHit]) -> [MemoryHit] {
        var groups: [[MemoryHit]] = []
        for hit in hits {
            if let i = groups.firstIndex(where: { $0.contains { sameThing($0.record, hit.record) } }) {
                groups[i].append(hit)
            } else {
                groups.append([hit])
            }
        }
        return groups.map { members in
            let best = members.max { completeness($0.record) < completeness($1.record) } ?? members[0]
            var merged = best
            merged.score = members.map(\.score).max() ?? best.score
            merged.related = members.filter { $0.record.id != best.record.id }.map(\.record).sorted { $0.seenAt > $1.seenAt }
            merged.distanceMeters = members.compactMap(\.distanceMeters).min()
            merged.signals.ftsRank = members.compactMap(\.signals.ftsRank).min()
            merged.signals.vectorRank = members.compactMap(\.signals.vectorRank).min()
            merged.signals.cosine = members.compactMap(\.signals.cosine).max()
            merged.signals.fuzzy = members.contains { $0.signals.fuzzy }
            return merged
        }
        .sorted { $0.score > $1.score }
    }

    static func sameThing(_ a: MemoryRecord, _ b: MemoryRecord) -> Bool {
        if let la = a.latitude, let oa = a.longitude, let lb = b.latitude, let ob = b.longitude,
           MemoryStore.haversine(la, oa, lb, ob) > 150 { return false }
        let ta = tokens(a.ocrText), tb = tokens(b.ocrText)
        let shared = ta.intersection(tb).count
        let smaller = min(ta.count, tb.count)
        let containment = smaller == 0 ? 0 : Double(shared) / Double(smaller)
        if let na = normalizedName(a.name), na == normalizedName(b.name), containment >= 0.4 { return true }
        if smaller >= 2, containment >= 0.8 { return true }
        let union = ta.union(tb).count
        return union > 0 && Double(shared) / Double(union) >= 0.5
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(MemoryStore.terms([text]).filter { $0.count >= 3 })
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let folded = MemoryStore.terms([name]).joined()
        return folded.count >= 3 ? folded : nil
    }

    /// Prefer the read with the fields people ask for and the most text.
    private static func completeness(_ r: MemoryRecord) -> Double {
        (r.phone == nil ? 0 : 1) + (r.hours == nil ? 0 : 1)
            + Double(min(tokens(r.ocrText).count, 30)) / 30
            + (r.confidence ?? 0.5) * 0.5
            + (r.status == .enriched ? 0.3 : 0)
    }

    /// The representative's OCR plus lines only other reads caught.
    static func mergedOCR(_ hit: MemoryHit) -> String {
        var lines = hit.record.ocrText.split(separator: "\n").map(String.init)
        var seen = MemoryStore.terms([hit.record.ocrText]).joined(separator: " ")
        for other in hit.related {
            for line in other.ocrText.split(separator: "\n").map(String.init) {
                let folded = MemoryStore.terms([line]).joined(separator: " ")
                guard folded.count >= 3, !seen.contains(folded) else { continue }
                lines.append(line)
                seen += " " + folded
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the reranker reads for one group.
    static func passage(_ hit: MemoryHit) -> String {
        let r = hit.record
        var parts = [r.kind, r.name, r.caption, r.hours.map { "hours: \($0)" }, r.phone.map { "phone: \($0)" },
                     r.visual, r.keywords, r.street.map { "street: \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        let ocr = mergedOCR(hit)
        parts.append(ocr.isEmpty ? "(no text read)" : ocr.replacingOccurrences(of: "\n", with: " | "))
        return parts.joined(separator: "\n")
    }

    private static func traceLabel(_ hit: MemoryHit) -> String {
        var s = "#\(hit.record.id) \(hit.record.name ?? hit.record.kind ?? String(hit.record.ocrText.prefix(14)))"
        if let logit = hit.signals.rerankLogit { s += String(format: " r%.2f", logit) }
        if let cosine = hit.signals.cosine { s += String(format: " c%.2f", cosine) }
        if let cosine = hit.signals.imageCosine { s += String(format: " i%.2f", cosine) }
        if !hit.related.isEmpty { s += " ×\(hit.related.count + 1)" }
        return s
    }

    // MARK: Evidence rule on the answer

    /// Code-side checks on the model's answer (the prompt alone is not enough):
    /// - every quote must appear in the text of a record it cites,
    /// - every number in the reply must appear in the OCR text of the cited records (the only
    ///   exceptions are when the frame was seen).
    /// Returns why the draft is rejected, or nil when it passes.
    private static func rejection(_ draft: AnswerDraft, hits: [MemoryHit], extra: String = "", liveLook: Bool = false) -> String? {
        guard AnswerLabel(rawValue: draft.label.uppercased()) == .seen else { return nil }
        let evidence = evidence(for: draft, in: hits)
        let ocr = evidence.map(mergedOCR).joined(separator: "\n")
        // Quotes: anything the model was shown (it may merge spans of two reads of one badge);
        // numbers stay strict: only the OCR of the records it cites.
        // The safety status and log shown to the model are evidence too (times, states).
        let fullText = (hits.map(recordText) + hits.flatMap(\.allRecords).map { promptTime($0.seenAt) } + [extra])
            .joined(separator: "\n")
        var reasons: [String] = []
        // Our own "(none)" placeholder for frames without text is not a quote.
        // Answered from the live picture: words the model reads in it that the phone's OCR
        // missed (a small watermark) are what it saw, so only the numbers are checked.
        if !liveLook, let quote = draft.quotes.first(where: { !$0.hasPrefix("(") && !EvidenceRule.quoteSupported($0, in: fullText) }) {
            reasons.append("the quote \"\(quote)\" is not in the text of the records listed in used_ids")
        }
        // What the model says it worked out itself (a sum, a solution) is not on any sign. Only
        // plain figures qualify: nothing with a colon, and nothing as long as a phone number.
        let worked = draft.derived.flatMap { EvidenceRule.numberRuns($0) }
            .filter { !$0.contains(":") && EvidenceRule.digits($0).count <= 6 }
            .map(EvidenceRule.canonicalNumber)
        // Worked from the live picture: the figures of the task as the model read them and of
        // its steps are its working too. The picture is what it read them from; the phone's
        // OCR misses matrix rows, exponents and small handwriting far more often than it does.
        let steps = liveLook && !(draft.working ?? "").isEmpty
            ? EvidenceRule.numberRuns((draft.problem ?? "") + "\n" + (draft.working ?? ""))
                .filter { !$0.contains(":") && EvidenceRule.digits($0).count <= 6 }
                .map(EvidenceRule.canonicalNumber)
            : []
        let allowed = seenTimes(evidence).union(EvidenceRule.numberRuns(extra).map(EvidenceRule.canonicalNumber)).union(worked).union(steps)
        let missing = EvidenceRule.unsupportedNumbers(in: draft.answer, ocr: ocr, allowed: allowed)
        if !missing.isEmpty {
            reasons.append("these numbers are not in the OCR text of the records listed in used_ids: \(missing.joined(separator: ", "))")
        }
        // Times said together must be written together in one record: opening hours pieced
        // together from two signs (or from the store's line and the pharmacy's line) are hours
        // nobody posted. From the Android side, which caught exactly that on the phone.
        if reasons.isEmpty {
            let sources = (evidence.map(mergedOCR) + [extra]).map { text -> Set<String> in
                Set(text.split(whereSeparator: \.isNewline).flatMap { EvidenceRule.numberRuns(String($0)) }.map(EvidenceRule.canonicalNumber))
            }
            for clause in draft.answer.split(whereSeparator: { ".!?;\n".contains($0) }) {
                let times = Set(EvidenceRule.numberRunsDetailed(String(clause))
                    .filter { $0.inRange || $0.run.contains(":") }
                    .map { EvidenceRule.canonicalNumber($0.run) }).subtracting(allowed)
                guard times.count >= 2, !sources.contains(where: { times.isSubset(of: $0) }) else { continue }
                reasons.append("the times in “\(clause.trimmingCharacters(in: .whitespaces).prefix(60))” are not written together in any one record: give each record's hours as written, separately")
                break
            }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    private static func evidence(for draft: AnswerDraft, in hits: [MemoryHit]) -> [MemoryHit] {
        let usedIDs = Set(draft.used_ids ?? [])
        let used = hits.filter { hit in hit.allRecords.contains { usedIDs.contains($0.id) } }
        return used.isEmpty ? Array(hits.prefix(1)) : used
    }

    /// When a frame was seen (every number of the date/time shown to the model, and how many
    /// minutes ago) may be said even though it is not on the sign.
    private static func seenTimes(_ evidence: [MemoryHit], now: Date = Date()) -> Set<String> {
        Set(evidence.flatMap(\.allRecords).flatMap { record -> [String] in
            let shown = promptTime(record.seenAt)
            let minutesAgo = max(0, Int(now.timeIntervalSince(record.seenAt) / 60))
            return (EvidenceRule.numberRuns(shown) + [String(minutesAgo), String(minutesAgo / 60)])
                .map(EvidenceRule.canonicalNumber)
        } + EvidenceRule.numberRuns(promptTime(now)).map(EvidenceRule.canonicalNumber))
    }

    /// Final result: a reply that still fails the checks becomes "not clearly seen"; a reply
    /// the model itself marks "inferred" is shown as its observations, labelled NOT SURE.
    private func checked(_ draft: AnswerDraft, question: String, hits: [MemoryHit],
                         started: ContinuousClock.Instant, trace: Trace, extra: String = "") -> AskResult {
        // Answered from the live view and no record cited: the live frame is the evidence,
        // not whichever memory record ranked first.
        var evidence = lookedLive && (draft.used_ids ?? []).isEmpty ? [] : Self.evidence(for: draft, in: hits)
        var label = AnswerLabel(rawValue: draft.label.uppercased()) ?? .unknown
        var answer = draft.answer
        var trace = trace
        // The model's own structured verdict wins over its label ("no, I did not see it" + GORDUM).
        if draft.found == false, label == .seen {
            label = .unknown
            trace.add("found=false")
        }
        // An "answer" that cites no record (no ids, no quotes) is conversation ("You're welcome!"):
        // shown without a verdict chip or evidence frames.
        if (draft.used_ids ?? []).isEmpty, draft.quotes.isEmpty, (draft.event_ids ?? []).isEmpty, !lookedLive,
           draft.found != true, label == .seen {
            trace.add("no records cited → chat")
            var r = result(question, draft.answer, .seen, [], true, started, nil, draft.language, trace)
            r.isCommand = true
            r.expectsReply = draft.expects_reply == true
            return r
        }
        if let why = Self.rejection(draft, hits: hits, extra: extra, liveLook: lookedLive && (draft.used_ids ?? []).isEmpty) {
            label = .unknown
            answer = draft.unclear_reply ?? Self.unclearText
            trace.add("evidence rule rejected")
            Log.pipeline.info("evidence rule rejected “\(draft.answer, privacy: .public)”: \(why, privacy: .public)")
        } else if label == .seen, draft.support == .inferred, draft.derived.isEmpty {
            // (An answer whose point is a figure worked out from what was read — a sum, a
            // solution — keeps its conclusion: that is what was asked for.)
            label = .unsure
            let ocr = evidence.map(Self.mergedOCR).joined(separator: "\n")
            if let observations = draft.observations, !observations.isEmpty,
               EvidenceRule.numbersSupported(in: observations, ocr: ocr, allowed: Self.seenTimes(evidence)) {
                answer = observations
            }
            trace.add("inferred → not sure")
        }
        // Not seen: there is no frame to show for it. (Before, the best-ranked frame was shown
        // as "the closest match", which read as an answer.) Likewise an answer that cites no
        // record — it rests on the conversation, the log or the agent's notes — shows no frame.
        if label == .unknown || (draft.used_ids ?? []).isEmpty { evidence = [] }
        return result(question, answer, label, evidence, true, started, nil, draft.language, trace)
    }

    /// Everything stored for a group (OCR and the vision model's fields), for quote checks.
    private static func recordText(_ hit: MemoryHit) -> String {
        hit.allRecords.flatMap { r in
            [r.ocrText, r.kind, r.name, r.phone, r.hours, r.otherText, r.caption, r.visual, r.street].compactMap { $0 }
        }.joined(separator: "\n")
    }

    /// No key / no answer from Nemotron: show the best retrieved frame, labelled honestly.
    /// (App UI language; without the model there is no understanding of the question.)
    private func offline(_ question: String, _ context: [MemoryHit], _ started: ContinuousClock.Instant,
                         note: String, _ trace: Trace) -> AskResult {
        guard let best = context.first else {
            return result(question, Self.emptyText, .unknown, [], false, started, note, nil, trace)
        }
        let r = best.record
        let text = Self.mergedOCR(best).split(separator: "\n").prefix(3).joined(separator: ", ")
        let time = r.seenAt.formatted(date: .omitted, time: .shortened)
        // Without the model there is no real answer: say so plainly, then what the search on the phone found.
        let answer = text.isEmpty
            ? String(localized: "I couldn't reach Nemotron, so I can't answer this properly right now. A search on the phone found a frame from \(time).")
            : String(localized: "I couldn't reach Nemotron, so I can't answer this properly right now. A search on the phone found this, seen at \(time): \(text).")
        return result(question, answer, .unknown, [best], false, started, note, nil, trace)
    }

    private func result(_ q: String, _ a: String, _ l: AnswerLabel, _ e: [MemoryHit], _ ai: Bool,
                        _ started: ContinuousClock.Instant, _ note: String?, _ language: String?, _ trace: Trace) -> AskResult {
        remember(Turn(question: q, answer: a + (lookedLive ? " [looked at the live view]" : ""),
                      ids: e.flatMap(\.allRecords).map(\.id), at: Date(), looked: lookedLive))
        return AskResult(question: q, answer: a, label: l, evidence: e, usedAI: ai,
                  latencyMs: (ContinuousClock.now - started).milliseconds,
                  note: note ?? (lookedLive ? String(localized: "Looked through the glasses just now.") : nil), language: language,
                  trace: trace.parts.isEmpty ? nil : trace.parts.joined(separator: " · "),
                  ranked: rankedForResult)
    }

    struct Trace: Sendable {
        var parts: [String] = []
        mutating func add(_ part: String) { parts.append(part) }
    }

    // MARK: Record text for the model

    private static let promptDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return f
    }()

    static func promptTime(_ date: Date) -> String { promptDate.string(from: date) }
    /// HH:mm, for conversation lines.
    static func clock(_ date: Date) -> String { Cue.stamp(date).suffix(5).description }

    /// Labelled record text: without labels the model did not tell a slogan from a sign's name.
    private static func describe(_ hit: MemoryHit, now: Date, position: (index: Int, count: Int)? = nil) -> String {
        let r = hit.record
        let minutesAgo = max(0, Int(now.timeIntervalSince(r.seenAt) / 60))
        var lines = ["id: \(r.id)", "Seen: \(promptTime(r.seenAt)) (minutes_ago: \(minutesAgo))"]
        if let episode = r.episodeID {
            lines.append("Episode: #\(episode)" + (position.map { ", frame \($0.index) of \($0.count)" } ?? ""))
        }
        if !hit.related.isEmpty {
            let times = hit.allRecords.map(\.seenAt)
            lines.append("Read \(hit.allRecords.count) times between \(promptTime(times.min()!)) and \(promptTime(times.max()!)); other ids: \(hit.related.map { String($0.id) }.joined(separator: ", "))")
        }
        if let street = r.street { lines.append("Street: \(street)") }
        if let area = r.area { lines.append("Area: \(area)") }
        if let distance = hit.distanceMeters { lines.append("distance_m: \(Int(distance.rounded()))") }
        if let kind = r.kind { lines.append("Type: \(kind)") }
        if let name = r.name { lines.append("Name on sign: \(name)") }
        if let phone = r.phone { lines.append("Phone on sign: \(phone)") }
        if let hours = r.hours { lines.append("Hours on sign: \(hours)") }
        if let other = r.otherText { lines.append("Other text on sign: \(other)") }
        if let visual = r.visual { lines.append(EvalSwitch.visual(visual)) }
        if let caption = r.caption { lines.append("Caption: \(caption)") }
        let ocr = mergedOCR(hit)
        lines.append("OCR text: \(ocr.isEmpty ? "(none)" : ocr.replacingOccurrences(of: "\n", with: " | "))")
        return lines.joined(separator: "\n")
    }

    /// At most `framesPerEpisode` frames, centred on the frames that were retrieved.
    private static func window(_ frames: [MemoryRecord], around ids: Set<Int64>) -> [MemoryRecord] {
        guard frames.count > framesPerEpisode else { return frames }
        let anchor = frames.firstIndex { ids.contains($0.id) } ?? 0
        let start = max(0, min(frames.count - framesPerEpisode, anchor - framesPerEpisode / 2))
        return Array(frames[start ..< start + framesPerEpisode])
    }

    /// One episode, its summary and its frames in the order seen (compact).
    private static func describe(_ episode: MemoryEpisode, frames: [MemoryRecord], total: Int, now: Date,
                                 position: (Int64) -> Int?) -> String {
        let endedAgo = max(0, Int(now.timeIntervalSince(episode.endedAt) / 60))
        var lines = ["Episode #\(episode.id): \(episode.title ?? "(no title yet)")",
                     "Time: \(promptTime(episode.startedAt)) to \(promptTime(episode.endedAt)) (ended minutes_ago: \(endedAgo)), \(total) frames"]
        if let street = episode.street { lines.append("Street: \(street)") }
        if let summary = episode.summary { lines.append("Summary: \(summary)") }
        lines.append(total > frames.count ? "Frames in order (part):" : "Frames in order:")
        for r in frames {
            let offset = Int(r.seenAt.timeIntervalSince(episode.startedAt))
            let order = position(r.id).map { "#\($0)" } ?? "#?"
            let ago = max(0, Int(now.timeIntervalSince(r.seenAt) / 60))
            var parts = ["\(order) id \(r.id)", "+\(offset / 60)m\(String(format: "%02d", offset % 60))s", "minutes_ago: \(ago)"]
            if let kind = r.kind { parts.append(kind) }
            if let name = r.name { parts.append("\"\(name)\"") }
            if let street = r.street, street != episode.street { parts.append("street: \(street)") }
            if let visual = r.visual.map(EvalSwitch.visual) {
                let things = visual.split(separator: "\n").filter { $0.hasPrefix("Visible things") || $0.hasPrefix("Spatial") || $0.hasPrefix("PICTURE") }
                if !things.isEmpty { parts.append(things.joined(separator: "; ")) }
            }
            if !r.ocrText.isEmpty { parts.append("OCR: " + String(r.ocrText.replacingOccurrences(of: "\n", with: " | ").prefix(160))) }
            lines.append("- " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    // App UI strings for the paths where the model did not answer.
    static let emptyText = String(localized: "I couldn't find anything about that in memory.")
    static let unclearText = String(localized: "I'm not sure I saw that, so I'd rather not guess.")
}

/// The visual re-check's prompt (see `QueryEngine.lookAgain`).
enum DoneCheck {
    static let system = """
    You check an answer Muisti gave from its log against the photos that log entry was made \
    from (the user's camera glasses, faces blurred, in time order; the last photo is the moment \
    of the entry). The answer may say that the user did something or that a thing is in some \
    state (a door locked, a stove turned off, a pill taken, keys left on a table). verdict: \
    "shown" when the photos show it, either the action happening or the state it left behind; \
    "not_shown" when the photos show the thing or the user at it, but not what the answer says \
    was done or is so; "not_claimed" when the answer claims no such thing (it says it was not \
    seen, or it is about a rule, a reminder or something the user said). Clock times, dates and \
    places in the answer come from the phone, not from the photos: leave them out of the check. \
    For not_shown, reply is one honest spoken sentence in the language of the answer: what the \
    photos do show, and that the thing itself was not seen. Otherwise reply is "". Output one \
    JSON object: {"verdict": "shown" | "not_shown" | "not_claimed", "reply": string}.
    """

    static let schema = #"""
    {"type":"object","properties":{"verdict":{"type":"string","enum":["shown","not_shown","not_claimed"]},"reply":{"type":"string"}},"required":["verdict","reply"]}
    """#

    struct Verdict: Decodable, Sendable {
        let verdict: String
        let reply: String?
    }
}

enum LookAgain {
    static let system = """
    You check one claim against a photo from the user's camera glasses, or a sheet of a few \
    numbered photos (faces are blurred). The claim answers the user's question about something \
    they saw. Decide whether the photo, or any one photo on the sheet, clearly shows what the \
    claim says was there. A thing only shown in a picture on a poster, \
    banner or screen counts only if the claim says it was a picture. Printed things (signs, QR \
    codes, logos) count as what they are. Where and when it was (street, city, place name, \
    time, what came before or after) come from the phone's location, clock and other photos, \
    not from this one: leave that part of the claim out and check only the thing itself. If \
    no photo clearly shows the thing, confirmed is false. Output one JSON object: {"confirmed": boolean, "seen": "a few words on what the \
    photo shows there"}.
    """

    static let schema = #"""
    {"type":"object","properties":{"confirmed":{"type":"boolean"},"seen":{"type":"string"}},"required":["confirmed","seen"]}
    """#

    struct Verdict: Decodable, Sendable {
        let confirmed: Bool
        let seen: String
    }
}

private extension String {
    /// Nil when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
