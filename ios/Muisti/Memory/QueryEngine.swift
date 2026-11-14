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

    private func remember(_ turn: Turn) {
        conversation.append(turn)
        if conversation.count > 6 { conversation.removeFirst(conversation.count - 6) }
    }

    /// Muisti spoke first (a warning or a yes/no question).
    func noteMuistiSaid(_ text: String) { remember(Turn(question: "(Muisti spoke first)", answer: text, ids: [], at: Date())) }

    /// The reply actually given (a warning may replace the model's acknowledgement).
    func noteExchange(question: String, answer: String) {
        if let last = conversation.last, last.question == question {
            conversation[conversation.count - 1].answer = answer
        } else {
            remember(Turn(question: question, answer: answer, ids: [], at: Date()))
        }
    }

    /// Starts a new conversation (the chat was cleared).
    func clearConversation() {
        conversation = []
        lastLive = nil
    }

    func setSafety(_ bridge: SafetyBridge) { safety = bridge }

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
        let recent = conversation.filter { now.timeIntervalSince($0.at) < 15 * 60 }.suffix(4)
        let talk = recent.map { "user: \($0.question)\nMuisti: \($0.answer)" }
        let looked = recent.last?.looked == true ? lastLive.map { Int(now.timeIntervalSince($0.at)) }.flatMap { $0 < 90 ? $0 : nil } : nil
        let safetyBridge = safety
        let hasKey = await ai.hasKey
        let place = position
        let decideTask = Task { () -> (decision: TurnTools.Decision?, ms: Int) in
            guard hasKey else { return (nil, 0) }
            let safetyText = await safetyBridge?.context() ?? ""
            return await Self.decide(ai, user: TurnTools.user(question: trimmed, now: now, conversation: Array(talk),
                                                              safety: safetyText, lookedSecondsAgo: looked, position: place))
        }
        let findTask = Task { await self.find(trimmed, location: location) }
        // A first message is complete by itself: its rerank starts at once. In a conversation
        // the model's own query may say more ("it" resolved), so the rerank waits ~0.2 s for it
        // (one rerank per question: two at once took twice as long each on the 68-question set).
        let searchTask: Task<(groups: [MemoryHit], trace: [String]), Never>? = recent.isEmpty ? Task {
            let found = await findTask.value
            return await self.reranked(found, query: trimmed)
        } : nil
        let (decision, decideMs) = await withTaskCancellationHandler { await decideTask.value } onCancel: {
            decideTask.cancel()
            findTask.cancel()
            searchTask?.cancel()
        }
        out.decision = decision
        switch decision {
        case .reply: out.trace.append("turn: reply \(decideMs) ms")
        case .look: out.trace.append("turn: tool look_now \(decideMs) ms")
        case .search(let query): out.trace.append("turn: tool search_memory \(decideMs) ms" + (query.map { " “\($0.prefix(60))”" } ?? ""))
        case .forget: out.trace.append("turn: tool forget_recent \(decideMs) ms")
        case .command(_, _, let tool): out.trace.append("turn: tool \(tool) \(decideMs) ms")
        case nil: out.trace.append("turn: no decision \(decideMs) ms")
        }
        switch decision {
        case .reply, .forget, .command:
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
        if case .search(let own?) = decision, own.caseInsensitiveCompare(trimmed) != .orderedSame, !Task.isCancelled {
            let second = await find(own, location: location)
            found = (Self.interleave(second.groups, found.groups), found.trace + second.trace.map { "query: " + $0 })
            query = own
        }
        let ranked = await reranked(found, query: query)
        out.groups = ranked.groups
        out.trace += ranked.trace
        return out
    }

    /// Query vector → search on the phone → one entry per sign/object.
    private func find(_ text: String, location: LocationFix?) async -> (groups: [MemoryHit], trace: [String]) {
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
        let hits = await store.search(search)
        // 3. One entry per sign/object: repeated and partial reads collapse into one group.
        let groups = Self.group(hits).map { Self.withDistance($0, from: location) }
        trace.append("search \((ContinuousClock.now - searchStarted).milliseconds) ms · \(hits.count) records → \(groups.count) groups")
        return (groups, trace)
    }

    /// 4. Cross-encoder rerank of the top groups. Slow (> 3 s) or failed: the fused order stays.
    private func reranked(_ found: (groups: [MemoryHit], trace: [String]), query text: String) async -> (groups: [MemoryHit], trace: [String]) {
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
            reranked.sort { ($0.signals.rerankLogit ?? -.infinity) > ($1.signals.rerankLogit ?? -.infinity) }
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
    private static func decide(_ ai: NemotronClient, user: String) async -> (decision: TurnTools.Decision?, ms: Int) {
        let began = ContinuousClock.now
        let outcome = await hedged(ai, seconds: 8) { host in
            try await ai.chatTools(system: TurnTools.system, user: user, tools: TurnTools.tools, route: host)
        }
        if case .failure(let error) = outcome.result {
            Log.net.info("turn call failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, privacy: .public)")
        }
        return ((try? outcome.result.get()).map(TurnTools.decision), (ContinuousClock.now - began).milliseconds)
    }

    func ask(_ question: String, location: LocationFix?, position: String? = nil, now: Date = Date()) async -> AskResult {
        self.position = position
        let started = ContinuousClock.now
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var trace = Trace()
        rankedForResult = []
        lookedLive = false
        let ai = self.ai
        await ai.beginQuestion()
        defer { Task { await ai.endQuestion() } }
        // Safety status/log (local, fast) is fetched while the question is embedded.
        let safetyBridge = safety
        async let safetyTextAsync = safetyBridge?.context() ?? ""
        // Follow-ups: the last few turns, and the live frame of a look that just happened.
        let turns = Array(conversation.filter { now.timeIntervalSince($0.at) < 15 * 60 }.suffix(4))
        let carried = turns.last?.looked == true ? lastLive.flatMap { now.timeIntervalSince($0.at) < 90 ? $0 : nil } : nil

        // 1–4. Turn decision + query vector + search + rerank. Already running if the same
        // words were heard a moment ago while the user was still finishing (`prepare`).
        let retrieval: Retrieval
        if let ready = prepared, ready.question == trimmed, now.timeIntervalSince(ready.at) < 20 {
            retrieval = await ready.task.value
            trace.add("prepared while listening")
        } else {
            prepared?.task.cancel()
            retrieval = await retrieve(trimmed, location: location, now: now)
        }
        prepared = nil
        retrieval.trace.forEach { trace.add($0) }
        let groups = retrieval.groups
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
        let carriedIDs = turns.last?.ids ?? []
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
        if let latest = await store.episodes(limit: 1).first, !episodeIDs.contains(latest.id) {
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
        let latest = await store.recent(limit: 5).map { r -> String in
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
        if let newest = await self.store.recent(limit: 1).first, !pictureRecords.contains(where: { $0.id == newest.id }),
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
        var user = MemoryPrompts.answerUser(question: trimmed, language: language, now: now, position: place,
                                            records: context.map { Self.describe($0, now: now, position: position[$0.record.id]) },
                                            episodes: episodeText, latest: latest, safety: safetyText, picture: pictureCaption,
                                            conversation: turns.map { "user: \($0.question)\nMuisti: \($0.answer)" + ($0.ids.isEmpty ? "" : " [relied on record ids \($0.ids.map(String.init).joined(separator: ", "))]") })
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
                trace.add("look_now: no live frame")
                var r = result(trimmed, String(localized: "I can't see anything right now: the glasses aren't sending images."), .unknown, [], true,
                               started, nil, language?.code, trace)
                r.isCommand = true
                return r
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
        var answered = await Self.answer(ai, user: user, image: image, trace: &trace)
        if case .failure = answered, image != nil {
            // A host that refuses the picture must not cost the answer: once more, text only.
            trace.add("retry without picture")
            answered = await Self.answer(ai, user: user, image: nil, trace: &trace)
        }
        let draft: AnswerDraft
        switch answered {
        case .success(let value):
            draft = value
        case .failure(let error):
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.net.error("answer call failed: \(why, privacy: .public)")
            return offline(trimmed, context, started, note: String(localized: "Nemotron didn't answer (\(why)); local search."), trace)
        }
        trace.add("answer \((ContinuousClock.now - answerStarted).milliseconds) ms\(image == nil ? "" : " · picture")")

        // One repair round: tell the model exactly which check failed and let it answer again.
        var final = draft
        if final.action == .answer, let why = Self.rejection(final, hits: pool, extra: safetyText, liveLook: lookedLive && (final.used_ids ?? []).isEmpty) {
            Log.pipeline.info("evidence check failed (\(why, privacy: .public)); asking again")
            let retry = user + "\n\nYour previous reply was rejected by the evidence check: \(why). " +
                "Answer again following the rules: leave out anything you cannot copy from the records' text."
            if case .success(let second) = await Self.answer(ai, user: retry, image: image, trace: &trace) {
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
            if case .success(let second) = await Self.answer(ai, user: retry, image: image, trace: &trace),
               AnswerLabel(rawValue: second.label.uppercased()) == .seen, second.found != false,
               Self.rejection(second, hits: pool, extra: safetyText, liveLook: lookedLive && (second.used_ids ?? []).isEmpty) == nil {
                final = second
                trace.add("second look")
            }
        }
        if let doubted = await lookAgain(final, question: trimmed, hits: pool, trace: &trace) { final = doubted }
        var answer = checked(final, question: trimmed, hits: pool, started: started, trace: trace, extra: safetyText)
        if let ids = final.event_ids, !ids.isEmpty {
            answer.safetyFrames = await safetyBridge?.frames(ids) ?? []
        }
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
        guard !readFromText else { return nil }
        let used = Set(draft.used_ids ?? [])
        guard let record = evidence.flatMap(\.allRecords).first(where: { used.contains($0.id) }) ?? evidence.first?.record,
              let jpeg = try? Data(contentsOf: store.frameURL(record)) else { return nil }
        let ai = ai
        let user = "Question: \(question)\nClaim: \(draft.answer)"
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

    /// The answer call, raced over both hosts of the same model (`hedged`): the host that is
    /// fast right now answers; the other joins after a short wait if the first stays silent.
    /// (Before: Verda got 12 s, then NVIDIA build 20 s, one after the other.)
    private static func answer(_ ai: NemotronClient, user: String, image: NemotronClient.ImagePart? = nil,
                               trace: inout Trace) async -> Result<AnswerDraft, Error> {
        let began = ContinuousClock.now
        let outcome = await hedged(ai, seconds: 20) { host in
            let draft = try await ai.chatJSON(AnswerDraft.self, system: MemoryPrompts.answerSystem, user: user, image: image,
                                              jsonSchema: MemoryPrompts.answerSchema, schemaName: "answer", maxTokens: 1000,
                                              temperature: 0, route: host)
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
        let allowed = seenTimes(evidence).union(EvidenceRule.numberRuns(extra).map(EvidenceRule.canonicalNumber))
        let missing = EvidenceRule.unsupportedNumbers(in: draft.answer, ocr: ocr, allowed: allowed)
        if !missing.isEmpty {
            reasons.append("these numbers are not in the OCR text of the records listed in used_ids: \(missing.joined(separator: ", "))")
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
        let evidence = lookedLive && (draft.used_ids ?? []).isEmpty ? [] : Self.evidence(for: draft, in: hits)
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
        } else if label == .seen, draft.support == .inferred {
            label = .unsure
            let ocr = evidence.map(Self.mergedOCR).joined(separator: "\n")
            if let observations = draft.observations, !observations.isEmpty,
               EvidenceRule.numbersSupported(in: observations, ocr: ocr, allowed: Self.seenTimes(evidence)) {
                answer = observations
            }
            trace.add("inferred → not sure")
        }
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
        // Without the model there is no real answer: say so plainly, then the closest frame.
        let answer = text.isEmpty
            ? String(localized: "I couldn't reach Nemotron, so I can't answer this properly right now. The closest frame is from \(time).")
            : String(localized: "I couldn't reach Nemotron, so I can't answer this properly right now. The closest thing I saw, at \(time), read: \(text).")
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
    static let unclearText = String(localized: "I didn't see that clearly; here's the closest frame.")
}

/// The visual re-check's prompt (see `QueryEngine.lookAgain`).
enum LookAgain {
    static let system = """
    You check one claim against one photo from the user's camera glasses (faces are blurred). \
    The claim answers the user's question about something they saw. Decide whether this photo \
    clearly shows what the claim says was there. A thing only shown in a picture on a poster, \
    banner or screen counts only if the claim says it was a picture. Printed things (signs, QR \
    codes, logos) count as what they are. Where and when it was (street, city, place name, \
    time, what came before or after) come from the phone's location, clock and other photos, \
    not from this one: leave that part of the claim out and check only the thing itself. If \
    the photo does not clearly show the thing, confirmed is false. Output one JSON object: {"confirmed": boolean, "seen": "a few words on what the \
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
