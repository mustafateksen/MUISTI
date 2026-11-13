import Foundation

struct AskResult: Sendable, Identifiable {
    let id = UUID()
    let question: String
    let answer: String
    let label: AnswerLabel
    let evidence: [MemoryHit]
    let usedAI: Bool
    let latencyMs: Int
    let note: String?
}

/// Question → plan (Nemotron) → local search (time/place/keywords/embedding) → answer from
/// evidence only (Nemotron) → evidence rule check. Falls back to a purely local answer when
/// there is no network or key, so "what did I just see?" still works offline.
actor QueryEngine {
    private let store: MemoryStore
    private let ai: NemotronClient

    init(store: MemoryStore, ai: NemotronClient) {
        self.store = store
        self.ai = ai
    }

    func ask(_ question: String, location: LocationFix?, now: Date = Date()) async -> AskResult {
        let started = ContinuousClock.now
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var aiUsed = false
        var note: String?

        // 1. "Son 10 dakikayı unut" works without any network.
        if let minutes = Self.localForgetMinutes(trimmed) {
            let removed = await store.delete(since: now.addingTimeInterval(-Double(minutes) * 60))
            return result(trimmed, Self.forgotText(minutes, removed, language: Self.guessLanguage(trimmed)), .seen, [], false, started, nil)
        }

        // 2. Plan.
        var plan: QueryPlan
        do {
            plan = try await ai.chatJSON(QueryPlan.self, system: MemoryPrompts.planSystem,
                                         user: MemoryPrompts.planUser(question: trimmed, now: ISO8601.string(from: now)),
                                         maxTokens: 300)
            aiUsed = true
        } catch {
            plan = Self.localPlan(trimmed)
            note = (error as? LocalizedError)?.errorDescription
        }
        let language = plan.language ?? Self.guessLanguage(trimmed)
        if plan.is_forget_command == true, let minutes = plan.forget_minutes {
            let removed = await store.delete(since: now.addingTimeInterval(-Double(minutes) * 60))
            return result(trimmed, Self.forgotText(minutes, removed, language: language), .seen, [], aiUsed, started, note)
        }

        // 3. Search on the phone.
        var search = MemorySearch()
        search.keywords = plan.keywords + Self.localKeywords(trimmed)
        if let minutes = plan.minutes_back, minutes > 0 { search.since = now.addingTimeInterval(-Double(minutes) * 60) }
        if let meters = plan.near_me_meters, let location {
            search.near = (location.latitude, location.longitude, Double(max(50, meters)))
        }
        if aiUsed {
            search.embedding = try? await ai.embed(([trimmed] + plan.keywords).joined(separator: " "), as: .query)
        }
        var hits = await store.search(search)
        if hits.isEmpty, search.since != nil || search.near != nil {
            // Nothing in the window: look wider, the answer will say when/where it was.
            search.since = nil
            search.near = nil
            hits = await store.search(search)
        }
        guard !hits.isEmpty else {
            return result(trimmed, Self.notSeenText(language), .unknown, [], aiUsed, started, note)
        }

        // 4. Answer from evidence only.
        let records = hits.map(\.record)
        if aiUsed {
            do {
                let draft = try await ai.chatJSON(
                    AnswerDraft.self,
                    system: MemoryPrompts.answerSystem(language: language),
                    user: "Question: \(trimmed)\n\nRecords:\n" + records.map(Self.describe).joined(separator: "\n\n"),
                    maxTokens: 400
                )
                return checked(draft, question: trimmed, hits: hits, language: language, started: started)
            } catch {
                note = (error as? LocalizedError)?.errorDescription
            }
        }
        // 5. Offline fallback: read back the best frame's text, labelled honestly.
        let best = records[0]
        return result(trimmed, Self.localAnswer(best, language: language), .seen, [hits[0]], aiUsed, started,
                      note ?? "Çevrimdışı: cevap yerel aramadan.")
    }

    // MARK: Evidence rule on the answer

    private func checked(_ draft: AnswerDraft, question: String, hits: [MemoryHit], language: String, started: ContinuousClock.Instant) -> AskResult {
        let used = hits.filter { draft.used_ids?.contains($0.record.id) ?? false }
        let evidence = used.isEmpty ? Array(hits.prefix(1)) : used
        let ocr = evidence.map(\.record.ocrText).joined(separator: "\n")
        var label = AnswerLabel(rawValue: draft.label.uppercased()) ?? .unknown
        var answer = draft.answer

        // Any quoted literal, and any long digit run in the answer, must be in the OCR text.
        let literalOK = draft.value.map { EvidenceRule.supports($0, in: ocr) } ?? true
        let digitRuns = answer.split(whereSeparator: { !$0.isNumber && $0 != " " && $0 != "-" })
            .map { EvidenceRule.digits(String($0)) }
            .filter { $0.count >= 5 }
        let ocrDigits = EvidenceRule.digits(ocr)
        let digitsOK = digitRuns.allSatisfy { ocrDigits.contains($0) }
        if label == .seen, !(literalOK && digitsOK) {
            label = .unknown
            answer = Self.notClearText(language)
            Log.pipeline.info("evidence rule rejected answer value \(draft.value ?? "-", privacy: .public)")
        }
        return result(question, answer, label, evidence, true, started, nil)
    }

    private func result(_ q: String, _ a: String, _ l: AnswerLabel, _ e: [MemoryHit], _ ai: Bool, _ started: ContinuousClock.Instant, _ note: String?) -> AskResult {
        AskResult(question: q, answer: a, label: l, evidence: e, usedAI: ai,
                  latencyMs: (ContinuousClock.now - started).milliseconds, note: note)
    }

    // MARK: Text helpers

    private static func describe(_ r: MemoryRecord) -> String {
        let time = r.seenAt.formatted(date: .abbreviated, time: .shortened)
        var lines = ["id: \(r.id)", "seen: \(time)"]
        if let street = r.street { lines.append("street: \(street)") }
        if let kind = r.kind { lines.append("kind: \(kind)") }
        if let name = r.name { lines.append("name: \(name)") }
        if let phone = r.phone { lines.append("phone: \(phone)") }
        if let hours = r.hours { lines.append("hours: \(hours)") }
        if let caption = r.caption { lines.append("caption: \(caption)") }
        lines.append("ocr_text: \(r.ocrText.isEmpty ? "(none)" : r.ocrText.replacingOccurrences(of: "\n", with: " | "))")
        return lines.joined(separator: "\n")
    }

    static func guessLanguage(_ text: String) -> String {
        let t = text.lowercased()
        if t.range(of: "[çğıöşü]", options: .regularExpression) != nil { return "tr" }
        let tr = ["ne", "neydi", "nedir", "nerede", "hangi", "var", "gördüm", "gördüğüm", "numara", "numarası", "saat", "kaç", "mı", "mi", "unut", "demosu", "telefonu"]
        let words = Set(t.split(separator: " ").map(String.init))
        return tr.contains(where: words.contains) ? "tr" : "en"
    }

    static func localForgetMinutes(_ text: String) -> Int? {
        let t = text.lowercased()
        guard t.contains("unut") || t.contains("forget") || t.contains("sil") || t.contains("delete") else { return nil }
        guard t.contains("dakika") || t.contains("minute") || t.contains("dk") else { return nil }
        if let match = t.range(of: #"\d+"#, options: .regularExpression), let n = Int(t[match]) { return min(n, 24 * 60) }
        return 10
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "what", "was", "is", "of", "in", "on", "at", "did", "i", "see", "number", "phone",
        "ne", "neydi", "bir", "bu", "şu", "o", "mı", "mi", "mu", "mü", "da", "de", "ve", "ile", "gördüğüm",
        "numarası", "numara", "telefon", "saat", "kaç", "nerede", "neresi", "az", "önce", "geçtiğimiz",
    ]

    static func localKeywords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    static func localPlan(_ text: String) -> QueryPlan {
        let t = text.lowercased()
        var minutes: Int?
        if t.contains("az önce") || t.contains("just now") || t.contains("geçtiğimiz") { minutes = 30 }
        var wanted: String?
        if t.contains("numara") || t.contains("telefon") || t.contains("phone") || t.contains("number") { wanted = "phone" }
        else if t.contains("saat") || t.contains("açık") || t.contains("hours") || t.contains("open") { wanted = "hours" }
        return QueryPlan(minutes_back: minutes, near_me_meters: nil, keywords: localKeywords(text),
                         wanted: wanted, language: guessLanguage(text), is_forget_command: false, forget_minutes: nil)
    }

    static func notSeenText(_ language: String) -> String {
        language == "tr" ? "Bunu görmedim." : "I didn't see that."
    }

    static func notClearText(_ language: String) -> String {
        language == "tr" ? "Bunu net görmedim; en yakın kareyi gösteriyorum." : "I didn't see that clearly; here is the closest frame."
    }

    static func forgotText(_ minutes: Int, _ removed: Int, language: String) -> String {
        language == "tr" ? "Son \(minutes) dakikayı unuttum (\(removed) kayıt silindi)."
                         : "Forgot the last \(minutes) minutes (\(removed) records deleted)."
    }

    static func localAnswer(_ r: MemoryRecord, language: String) -> String {
        let time = r.seenAt.formatted(date: .omitted, time: .shortened)
        let text = r.ocrText.split(separator: "\n").prefix(3).joined(separator: ", ")
        let place = r.street.map { language == "tr" ? ", \($0) civarında" : " near \($0)" } ?? ""
        if language == "tr" {
            return text.isEmpty ? "Saat \(time)\(place) bir kare var ama yazı okunmadı." : "Saat \(time)\(place) gördüğüm kayıtta şu yazıyor: \(text)."
        }
        return text.isEmpty ? "There is a frame from \(time)\(place) but no text was read." : "At \(time)\(place) I saw: \(text)."
    }
}
