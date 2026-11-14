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
    /// The last question and reply, so "yes" / "not now" can answer what Muisti just said.
    private var previous: (question: String, answer: String, at: Date)?

    /// Muisti spoke first (a warning or a yes/no question): that is the previous exchange.
    func noteMuistiSaid(_ text: String) { previous = ("(Muisti spoke first)", text, Date()) }

    /// The reply actually given (a warning may replace the model's acknowledgement).
    func noteExchange(question: String, answer: String) { previous = (question, answer, Date()) }

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

    func ask(_ question: String, location: LocationFix?, now: Date = Date()) async -> AskResult {
        let started = ContinuousClock.now
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var trace = Trace()
        rankedForResult = []
        let ai = self.ai
        await ai.beginQuestion()
        defer { Task { await ai.endQuestion() } }
        // Safety status/log (local, fast) is fetched while the question is embedded.
        let safetyBridge = safety
        async let safetyTextAsync = safetyBridge?.context() ?? ""

        // 1. Query vector (~0.3–0.9 s; skipped when embeddings are off or slow).
        let (embedding, embedMs) = await Self.queryVector(ai, question: trimmed)
        trace.add(embedding == nil ? "no vector" : "vector \(embedMs) ms")

        // 2. Retrieve on the phone.
        let searchStarted = ContinuousClock.now
        var search = MemorySearch()
        search.keywords = [trimmed]
        search.limit = 60
        search.embedding = embedding
        let hits = await store.search(search)

        // 3. One entry per sign/object: repeated and partial reads collapse into one group.
        var groups = Self.group(hits).map { Self.withDistance($0, from: location) }
        trace.add("search \((ContinuousClock.now - searchStarted).milliseconds) ms · \(hits.count) records → \(groups.count) groups")

        // 4. Cross-encoder rerank of the top groups.
        if !groups.isEmpty, await ai.rerankEnabled {
            let head = Array(groups.prefix(Self.rerankDepth))
            let passages = head.map(Self.passage)
            let rerankStarted = ContinuousClock.now
            if let logits = await withTimeout(seconds: 8, { try await ai.rerank(query: trimmed, passages: passages) }),
               logits.count == head.count {
                var reranked = zip(head, logits).map { hit, logit -> MemoryHit in
                    var hit = hit
                    hit.signals.rerankLogit = logit
                    return hit
                }
                reranked.sort { ($0.signals.rerankLogit ?? -.infinity) > ($1.signals.rerankLogit ?? -.infinity) }
                groups = reranked + groups.dropFirst(head.count)
                trace.add("rerank \((ContinuousClock.now - rerankStarted).milliseconds) ms (\(await ai.rerankModelName.split(separator: "/").last ?? ""))")
            } else {
                trace.add("no rerank")
            }
        }
        let context = Array(groups.prefix(Self.answerContext))
        rankedForResult = groups.prefix(Self.rerankDepth).map { $0.allRecords.map(\.id) }
        if !context.isEmpty { trace.add("top: " + context.prefix(3).map(Self.traceLabel).joined(separator: ", ")) }

        // 5. One model call: understand the question and answer from the records only.
        guard await ai.hasKey else {
            return offline(trimmed, context, started, note: "No Nemotron key; local search.", trace)
        }
        // Episodes of the best records: the frames seen just before and after them, in order,
        // so the model can answer "what was next to / after / on the same walk as X".
        var episodeIDs: [Int64] = []
        for id in context.prefix(5).compactMap(\.record.episodeID) where !episodeIDs.contains(id) { episodeIDs.append(id) }
        episodeIDs = Array(episodeIDs.prefix(Self.episodeContext))
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
        let safetyText = await safetyTextAsync
        // The frames of the first records, as one picture: the model looks at them as well as
        // reading their text (colours, layout, what the OCR missed).
        let pictureRecords = context.prefix(4).map(\.record)
        let store = self.store
        let picture = Self.montage(pictureRecords.map { store.frameURL($0) })
        let pictureCaption = picture == nil ? nil : "a grid of " + pictureRecords.enumerated()
            .map { "\($0.offset + 1) = record id \($0.element.id)" }.joined(separator: ", ")
            + " (1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right)"
        let user = MemoryPrompts.answerUser(question: trimmed, language: language, now: now, hasLocation: location != nil,
                                            records: context.map { Self.describe($0, now: now, position: position[$0.record.id]) },
                                            episodes: episodeText, latest: latest, safety: safetyText, picture: pictureCaption,
                                            previous: previous.flatMap { now.timeIntervalSince($0.at) < 300 ? "user: \($0.question) / Muisti: \($0.answer)" : nil })
        let image = picture.map { NemotronClient.ImagePart(jpeg: $0) }
        #if DEBUG
        // Last prompt, for checking retrieval/episode context (Documents/last_prompt.txt).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? user.write(to: docs.appendingPathComponent("last_prompt.txt"), atomically: true, encoding: .utf8)
        }
        #endif
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
            return offline(trimmed, context, started, note: "Nemotron didn't answer (\(why)); local search.", trace)
        }
        trace.add("answer \((ContinuousClock.now - answerStarted).milliseconds) ms\(image == nil ? "" : " · picture")")

        // Muisti Turva commands: the reply is an acknowledgement / read-back, run by the caller.
        if let command = draft.safetyCommand {
            trace.add("safety: \(draft.action.rawValue)")
            var r = result(trimmed, draft.answer, .seen, [], true, started, nil, draft.language, trace)
            r.safety = command
            r.isCommand = true
            return r
        }

        // One repair round: tell the model exactly which check failed and let it answer again.
        var final = draft
        if final.action == .answer, let why = Self.rejection(final, hits: pool, extra: safetyText) {
            Log.pipeline.info("evidence check failed (\(why, privacy: .public)); asking again")
            let retry = user + "\n\nYour previous reply was rejected by the evidence check: \(why). " +
                "Answer again following the rules: leave out anything you cannot copy from the records' text."
            if case .success(let second) = await Self.answer(ai, user: retry, image: image, trace: &trace) {
                final = second
                trace.add("repair round")
            }
        }

        // 6. Forget request, as understood by the model.
        if draft.action == .forget {
            guard let minutes = draft.forget_minutes, (1...Self.maxForgetMinutes).contains(minutes) else {
                trace.add("forget: invalid span (\(draft.forget_minutes.map(String.init) ?? "-"))")
                return result(trimmed, draft.unclear_reply ?? draft.answer, .unknown, [], true, started, nil, draft.language, trace)
            }
            let since = now.addingTimeInterval(-Double(minutes) * 60)
            let removed = await store.delete(since: since)
            await safetyBridge?.forget(since)
            trace.add("forget: \(minutes) min, \(removed) records deleted")
            var r = result(trimmed, draft.answer, .seen, [], true, started, nil, draft.language, trace)
            r.isCommand = true
            return r
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
               Self.rejection(second, hits: pool, extra: safetyText) == nil {
                final = second
                trace.add("second look")
            }
        }
        var answer = checked(final, question: trimmed, hits: pool, started: started, trace: trace, extra: safetyText)
        if let ids = final.event_ids, !ids.isEmpty {
            answer.safetyFrames = await safetyBridge?.frames(ids) ?? []
        }
        return answer
    }

    /// The answer call: the configured Nemotron (Verda) gets 12 s; if it fails or is slow, the
    /// same model on NVIDIA build answers. (Verda alone left answers as "Nemotron didn't answer"
    /// when it was busy.)
    private static func answer(_ ai: NemotronClient, user: String, image: NemotronClient.ImagePart? = nil,
                               trace: inout Trace) async -> Result<AnswerDraft, Error> {
        let primary = await withTimeoutResult(seconds: 12) {
            try await ai.chatJSON(AnswerDraft.self, system: MemoryPrompts.answerSystem, user: user, image: image,
                                  jsonSchema: MemoryPrompts.answerSchema, schemaName: "answer", maxTokens: 1000, temperature: 0)
        }
        guard case .failure(let error) = primary, await ai.fallbackAvailable else { return primary }
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.net.info("answer: primary failed (\(why, privacy: .public)); using NVIDIA build")
        trace.add("fallback endpoint (\(why.prefix(40)))")
        return await withTimeoutResult(seconds: 20) {
            try await ai.chatJSON(AnswerDraft.self, system: MemoryPrompts.answerSystem, user: user, image: image,
                                  jsonSchema: MemoryPrompts.answerSchema, schemaName: "answer", maxTokens: 1000, temperature: 0,
                                  route: .fallback)
        }
    }

    /// Up to four keyframes (already blurred) in a 2×2 grid, numbered 1–4, as one JPEG: one
    /// picture works on every host, several do not.
    static func montage(_ urls: [URL], cell: CGFloat = 640) -> Data? {
        let images = urls.prefix(4).compactMap { url -> CGImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageData.thumbnail(data, maxPixel: Int(cell))
        }
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
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let code = language.rawValue
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        return (code, name)
    }

    private static func queryVector(_ ai: NemotronClient, question: String) async -> ([Float]?, Int) {
        let started = ContinuousClock.now
        guard await ai.embeddingsEnabled else { return (nil, 0) }
        let vector = await withTimeout(seconds: 6) { try await ai.embed(question, as: .query) }
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
        if !hit.related.isEmpty { s += " ×\(hit.related.count + 1)" }
        return s
    }

    // MARK: Evidence rule on the answer

    /// Code-side checks on the model's answer (the prompt alone is not enough):
    /// - every quote must appear in the text of a record it cites,
    /// - every number in the reply must appear in the OCR text of the cited records (the only
    ///   exceptions are when the frame was seen).
    /// Returns why the draft is rejected, or nil when it passes.
    private static func rejection(_ draft: AnswerDraft, hits: [MemoryHit], extra: String = "") -> String? {
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
        if let quote = draft.quotes.first(where: { !$0.hasPrefix("(") && !EvidenceRule.quoteSupported($0, in: fullText) }) {
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
        let evidence = Self.evidence(for: draft, in: hits)
        var label = AnswerLabel(rawValue: draft.label.uppercased()) ?? .unknown
        var answer = draft.answer
        var trace = trace
        // The model's own structured verdict wins over its label ("no, I did not see it" + GORDUM).
        if draft.found == false, label == .seen {
            label = .unknown
            trace.add("found=false")
        }
        if let why = Self.rejection(draft, hits: hits, extra: extra) {
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
            ? "I couldn't reach Nemotron, so I can't answer this properly right now. The closest frame is from \(time)."
            : "I couldn't reach Nemotron, so I can't answer this properly right now. The closest thing I saw, at \(time), read: \(text)."
        return result(question, answer, .unknown, [best], false, started, note, nil, trace)
    }

    private func result(_ q: String, _ a: String, _ l: AnswerLabel, _ e: [MemoryHit], _ ai: Bool,
                        _ started: ContinuousClock.Instant, _ note: String?, _ language: String?, _ trace: Trace) -> AskResult {
        previous = (q, a, Date())
        return AskResult(question: q, answer: a, label: l, evidence: e, usedAI: ai,
                  latencyMs: (ContinuousClock.now - started).milliseconds, note: note, language: language,
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
        if let distance = hit.distanceMeters { lines.append("distance_m: \(Int(distance.rounded()))") }
        if let kind = r.kind { lines.append("Type: \(kind)") }
        if let name = r.name { lines.append("Name on sign: \(name)") }
        if let phone = r.phone { lines.append("Phone on sign: \(phone)") }
        if let hours = r.hours { lines.append("Hours on sign: \(hours)") }
        if let other = r.otherText { lines.append("Other text on sign: \(other)") }
        if let visual = r.visual { lines.append(visual) }
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
            if let visual = r.visual {
                let things = visual.split(separator: "\n").filter { $0.hasPrefix("Visible things") || $0.hasPrefix("Spatial") || $0.hasPrefix("PICTURE") }
                if !things.isEmpty { parts.append(things.joined(separator: "; ")) }
            }
            if !r.ocrText.isEmpty { parts.append("OCR: " + String(r.ocrText.replacingOccurrences(of: "\n", with: " | ").prefix(160))) }
            lines.append("- " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    // App UI strings for the paths where the model did not answer.
    static let emptyText = "I couldn't find anything about that in memory."
    static let unclearText = "I didn't see that clearly; here's the closest frame."
}
