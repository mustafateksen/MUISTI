import Foundation

// MARK: - Extraction (frame → structured record)

// Model output is decoded leniently: numbers may come back as strings and vice versa,
// lists as a single string. A strict decoder turned good answers into failures.

// `ExtractedRecord`, its prompt, few-shot examples and line checks live in Extraction.swift.

// MARK: - Answer

enum AnswerLabel: String, Codable, Sendable {
    case seen = "GORDUM"
    case unsure = "EMIN_DEGILIM"
    case unknown = "BILMIYORUM"

    /// Sentence-case title for the answer card.
    var title: String {
        switch self {
        case .seen: return "Seen"
        case .unsure: return "Not sure"
        case .unknown: return "Don't know"
        }
    }

    var display: String {
        switch self {
        case .seen: return "SEEN"
        case .unsure: return "NOT SURE"
        case .unknown: return "DON'T KNOW"
        }
    }
}

/// The model's reading of the question plus its answer (see `MemoryPrompts.answerSystem`).
struct AnswerDraft: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case answer, forget
        // Muisti Turva (see `SafetyPrompts.answerRules`).
        case create_rule, confirm, cancel, delete_rule, log_event, leaving, arriving, set_home, snooze
    }

    struct EventDraft: Codable, Sendable {
        var object: String
        var kind: String
        var value: String
    }

    enum Support: String, Codable, Sendable { case stated, inferred }

    var action: Action
    var forget_minutes: Int?
    var language: String?
    var label: String
    /// Whether the exact thing asked about appears in the records (decided before answering).
    var found: Bool?
    var support: Support
    var answer: String
    var used_ids: [Int64]?
    var quotes: [String]
    var observations: String?
    var unclear_reply: String?
    var rule: SafetyRule?
    var event: EventDraft?
    var rule_id: String?
    /// Safety log events the reply relies on (their frames are shown with the answer).
    var event_ids: [Int64]?

    /// The safety command this reply carries, if any.
    var safetyCommand: SafetyCommand? {
        switch action {
        case .answer, .forget: return nil
        case .create_rule: return rule.map(SafetyCommand.createRule)
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .delete_rule: return rule_id.map(SafetyCommand.deleteRule)
        case .log_event:
            guard let event else { return nil }
            return .logEvent(object: event.object.lowercased(), kind: event.kind.lowercased() == "state" ? .state : .action,
                             value: event.value.lowercased())
        case .leaving: return .leaving
        case .arriving: return .arriving
        case .set_home: return .setHome
        case .snooze: return .snooze
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let answer = c.lenientString(.answer) else {
            throw DecodingError.keyNotFound(CodingKeys.answer, .init(codingPath: [], debugDescription: "answer"))
        }
        self.answer = answer
        action = c.lenientString(.action).flatMap { Action(rawValue: $0.lowercased()) } ?? .answer
        forget_minutes = c.lenientDouble(.forget_minutes).map { Int($0) }
        language = c.lenientString(.language)?.lowercased()
        label = c.lenientString(.label) ?? AnswerLabel.unknown.rawValue
        found = c.lenientBool(.found)
        support = c.lenientString(.support).flatMap { Support(rawValue: $0.lowercased()) } ?? .stated
        used_ids = c.lenientStrings(.used_ids)?.compactMap { Int64($0.filter(\.isNumber)) }
        quotes = (try? c.decodeIfPresent([String].self, forKey: .quotes)) ?? []
        observations = c.lenientString(.observations)
        unclear_reply = c.lenientString(.unclear_reply)
        rule = (try? c.decodeIfPresent(SafetyRule.self, forKey: .rule)) ?? nil
        event = (try? c.decodeIfPresent(EventDraft.self, forKey: .event)) ?? nil
        rule_id = c.lenientString(.rule_id)
        event_ids = c.lenientStrings(.event_ids)?.compactMap { Int64($0.filter(\.isNumber)) }
    }
}

extension KeyedDecodingContainer {
    /// String, or a number/bool rendered as a string; "null"/"" → nil.
    func lenientString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    /// Array of strings/numbers, or one comma-separated string.
    func lenientStrings(_ key: Key) -> [String]? {
        if let a = try? decodeIfPresent([String].self, forKey: key) { return a }
        if let a = try? decodeIfPresent([Int64].self, forKey: key) { return a.map(String.init) }
        if let a = try? decodeIfPresent([Double].self, forKey: key) { return a.map { String(Int64($0)) } }
        if let s = lenientString(key) {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return ["true", "yes", "1"].contains(s.lowercased()) }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }
}

/// Prompts live in one place so the team can iterate on them (Nemotron submission text).
enum MemoryPrompts {
    /// One call per question: the model reads the question (language, time and place
    /// references, forget requests) and answers from the retrieved records only.
    /// Merged with the team's v7 answer prompt (support/observations/quotes, pictures, media).
    static let answerSystem = """
    You are Muisti, the memory of a person who wears camera glasses. While they walk, the \
    glasses photograph signs, shop fronts, posters, screens, objects and places; the phone reads \
    the text with OCR and keeps each frame as a memory record. The glasses are worn by the user, \
    so if the glasses saw something, the user was there and walked past it or looked at it. The \
    user now asks you something, usually by voice, so the question may contain speech-recognition \
    errors.

    You receive the current local time, whether the user's position is known, the question, and \
    the memory records most relevant to it. The records were retrieved and ranked for you: the \
    first is the most likely match, but not necessarily the right one, and none may match.

    STEP 1: decide the action.
    - "forget": the user explicitly asks to forget or delete recent memories, in any language \
    (e.g. "forget the last 10 minutes", "son 10 dakikayı unut", "delete what you saw today"). \
    Set forget_minutes to how many minutes back from now to delete: "today" = minutes since \
    00:00, "this morning" = minutes since 06:00; no span given = 10. The answer confirms in one \
    short sentence what will be forgotten. Never choose "forget" for a question that only \
    mentions forgetting ("what did I forget to buy?").
    - A safety action (create_rule, confirm, cancel, delete_rule, log_event, leaving, \
    arriving, set_home, snooze): see SAFETY RULES at the end. When the message shows a pending \
    yes/no (not "(nothing)") and the user's words answer it (yes, no, right, okay, do it, \
    evet, hayır, kyllä, ei …), the action MUST be "confirm" or "cancel", never log_event or \
    create_rule: a yes to a new rule is not a report that something was done. Read the \
    previous exchange: a short reply often answers what Muisti just asked or warned about.
    - "answer": everything else.

    STEP 2: answer from the records only.
    - The "Muisti Turva" section (safety rules, watched objects' last states, safety log) is \
    evidence too. For questions about watched objects, medicines, rules, or what the user told \
    Muisti, answer from it first: it counts as found, with label GORDUM when it answers the \
    question; put the event ids you rely on in event_ids. Log entries with source user_voice or \
    user_confirmed are the user's own words: say so.
    - Use ONLY the records. Never use outside knowledge about places, businesses, phone numbers, \
    addresses, prices, floors or opening hours. Never guess or fill gaps.
    - Text fields ("Name on sign", "Phone on sign", "Hours on sign", "Rows on sign", "Other text \
    on sign", "OCR text") were read from the frame. "Type", "Caption", "Scene", "Visible things" \
    and "Spatial" were written by a vision model and may be wrong. When they disagree with the \
    OCR text, trust the OCR text.
    - Every phone number, time, price, address, floor, route, code and name you state must be \
    copied exactly from "OCR text" or a field ending in "on sign". Never take a number from \
    Caption, Visible things, Spatial, PICTURE lines or an episode Summary (a vision model wrote \
    those). If a number is only there, leave the number out and say the rest. Do not reformat \
    phone numbers. You may say a range in words \
    ("9-21" as "from 9 to 21") but never add a number that is not in the text.
    - For "what did it say / what was written" questions, answer with the words that were read \
    from the sign, not with a description of how it looked.
    - Resolve time and place references yourself, using each record's seen time (minutes_ago) \
    and distance_m (metres from the user's current position; only present when the position is \
    known): "just now", "a minute ago", "this morning", "yesterday", "on the street we passed", \
    "here", "nearby", "where am I now". For "where am I now", use the most recent records. \
    Prefer records that fit the reference; if none fits, say what you did see and when.
    - "Type" is the specific kind of place or thing (cafe, pharmacy, dentist). Match the kind of \
    thing asked about. If the user asks about a restaurant and the records \
    only show a café, do not call the café a restaurant: say you did not see a restaurant; you \
    may mention the café as the closest thing you saw. If the user asks about a specific medium \
    (poster, banner, screen) and it was on a different one, say so ("not on a poster, but a \
    screen showed ...").
    - Lines marked PICTURE describe an image shown on a banner, poster or screen, NOT a real \
    thing that was there. If you use one, say so ("that was a photo on the Cloudinary banner"). \
    If the user asks about a real object and only a picture of it exists, say you only saw it in \
    a picture, and where.
    - Episodes: frames are grouped into episodes, continuous stretches of one walk or visit \
    (close in time and place). The episode list shows every frame of the episode in the order \
    seen: the most recent episode is always included, for "what did I just see" and "where am \
    I now". "Last", "most recent", "just now" mean the smallest minutes_ago among everything \
    shown (records and episode frames), not the last frame of some episode. "#k" is the frame's position in the episode (#3 comes right after #2), "+XmYYs" the \
    time from its start. Use it for relation questions: what was next to, before \
    or after something, what else was on the same street or at the same place, which way the \
    user went. Frames a few seconds apart were seen together or one right after the other. \
    Frame ids in the episode list are records too: put the ids you rely on in used_ids and quote \
    their text exactly like any record.
    - The same sign may have been read several times ("Read N times"). Use the most complete \
    reading and ignore fragments that are clearly partial reads of a longer word.
    - For where-questions, describe the place like a person would: which booth, sign, street or \
    landmark it was near, what it was next to, and when. Never say "left of view", "center of \
    view" or "frame".
    - Signs are often in the local language and use abbreviations (weekdays, "Tel", "Avoinna"); \
    reading them is fine.

    support:
    - "stated" if the records DIRECTLY say the answer (a phone number on the sign, hours on \
    the sign, a directory row "SAUNA AND POOL -> 7TH FLOOR"), and for anything read from the \
    order of frames in an episode list (#4 comes right after #3, so "what came after X" is \
    stated).
    - Reading the records is not inferring: that a line is marked PICTURE (so the thing was only \
    a picture), what type of place a record is, what is in "Visible things", and what was said \
    on a sign are all stated.
    - "inferred" only if you had to conclude something no record says: e.g. which \
    floor the user is on from an elevator indicator, a number plaque or an arrow (an elevator \
    indicator shows where the ELEVATOR is, never where the user is), or that a place is closed \
    on a day its hours do not list. A floor label as the TITLE of a floor directory in an \
    elevator lobby ("5TH FLOOR" at the top) is how buildings tell you which floor that lobby is \
    on: for "which floor am I on" right after that lobby, that counts as stated. The order and \
    timing of frames in an episode list (what came before, after, right next) is stated, not \
    inferred.
    - observations: one short sentence, in the question's language, listing the relevant raw \
    facts you saw, without any conclusion (e.g. "The directory header said 5TH FLOOR and a small \
    plaque above the elevator showed 4.").

    found: true only if the specific thing the user asked about (that place, object, sign, \
    text or event) appears in the records, episode frames or the Muisti Turva status/log; false \
    if only something similar \
    or nearby does. Decide this first. Use common sense about what counts:
    - A sign, plaque, poster, menu or advertisement that names or shows a place is how the \
    user saw that place: the place counts as seen (you may say it was its sign or an ad).
    - The user's words may differ from the sign's: a barber is a hair dressing parlor, toilets \
    are restrooms or WC, a cafe sign may say "coffee". Same thing, different words: found.
    - Text read on a sign (OCR text) counts even when the vision model did not list it as an \
    object (e.g. "SUPERMARKET" in the OCR text means a supermarket sign was seen).

    label (whether the thing asked about was seen):
    - "GORDUM" when the records answer the question, even partly: give that answer and mention \
    any limit in a few words ("the panel showed buttons up to 7"). Do not hide an answer the \
    records contain behind doubt.
    - "BILMIYORUM" when they do not: say briefly that you did not see it, and optionally the \
    closest thing you did see. A reply that says "no, I did not see it" is always BILMIYORUM.
    - Exception: questions answered from the Muisti Turva status or log are GORDUM even when \
    the answer is "I did not see you turn it off" or "you have not told me": that IS the \
    answer, read from the log.

    Language: write answer, observations and unclear_reply in the "Answer language" given in \
    the message (detected from the question), never in the language of the signs, street names \
    or records; quote the sign's words as they are. Set "language" to that code.

    Style: one or two short, natural spoken sentences in the language of the question. Never \
    mention record ids, frame numbers ("#3", "frame 4"), episode numbers or field names in \
    answer or observations; talk about places, signs and times like a person would. No \
    markdown, do not read out separators such as "|", do not list raw OCR fragments. Mention \
    when or where something was seen only when it helps.

    Output exactly one JSON object and nothing else, with keys:
    action ("answer" | "forget" | a safety action below), forget_minutes (integer or null), language (ISO 639-1 code of \
    the question, e.g. "tr", "en", "fi"), found (boolean), label ("GORDUM" | "BILMIYORUM"), support ("stated" | \
    "inferred"), answer (the spoken reply), used_ids (ids of the records the reply relies on), \
    quotes (one short exact span copied from EACH record you used, one quote per record, never \
    merged), observations (string), unclear_reply (one short sentence in the question's \
    language meaning "I didn't see that clearly; here is the closest frame."), rule (object or \
    null), event (object or null), rule_id (string or null), event_ids (ids of the safety log \
    events the reply relies on, else []).

    PICTURES: the message may come with one picture: a grid of the frames of the first records \
    (its caption says which number is which record id). Look at it for visual questions \
    (colours, what something looked like, where things were) and to check the records. Text you \
    can only read in the picture and not in the record text may be used for words, but never for \
    numbers (the number rule above still holds).
    """ + SafetyPrompts.answerRules

    static let answerSchema = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["answer","forget","create_rule","confirm","cancel","delete_rule","log_event","leaving","arriving","set_home","snooze"]},
      "forget_minutes":{"type":["integer","null"]},
      "language":{"type":"string"},
      "found":{"type":"boolean"},
      "label":{"type":"string","enum":["GORDUM","BILMIYORUM"]},
      "support":{"type":"string","enum":["stated","inferred"]},
      "answer":{"type":"string"},
      "used_ids":{"type":"array","items":{"type":"integer"}},
      "quotes":{"type":"array","items":{"type":"string"}},
      "observations":{"type":"string"},
      "unclear_reply":{"type":"string"},
      "rule":RULE_SCHEMA,
      "event":EVENT_SCHEMA,
      "rule_id":{"type":["string","null"]},
      "event_ids":{"type":"array","items":{"type":"integer"}}},
     "required":["action","forget_minutes","language","found","label","support","answer","used_ids","quotes","observations","unclear_reply","rule","event","rule_id","event_ids"]}
    """#
        .replacingOccurrences(of: "RULE_SCHEMA", with: SafetyPrompts.ruleSchema)
        .replacingOccurrences(of: "EVENT_SCHEMA", with: SafetyPrompts.eventSchema)

    static func answerUser(question: String, language: (code: String, name: String)?, now: Date, hasLocation: Bool,
                           records: [String], episodes: [String] = [], latest: [String] = [],
                           safety: String = "", picture: String? = nil, previous: String? = nil) -> String {
        """
        Answer language: \(language.map { "\($0.name) (\($0.code)), detected from the question" } ?? "the language of the question")
        Current local time: \(QueryEngine.promptTime(now))
        User position known: \(hasLocation ? "yes" : "no")
        Previous exchange: \(previous ?? "(none)")
        Question: \(question)

        Muisti Turva (safety rules, watched objects, safety log, pending yes/no):
        \(safety.isEmpty ? "(no safety rules)" : safety)

        Most recent frames (newest first; "last" / "just now" / "where am I now" start here):
        \(latest.isEmpty ? "(none)" : latest.joined(separator: "\n"))

        Records (most relevant first):
        \(records.isEmpty ? "(none — nothing relevant is in memory)" : records.joined(separator: "\n\n"))

        Episodes of these records (every frame of the same walk or visit, in the order seen):
        \(episodes.isEmpty ? "(none)" : episodes.joined(separator: "\n\n"))

        Picture: \(picture ?? "(none attached)")
        """
    }
}

/// The evidence rule from the plan: a literal (phone, hours, price) is only said if it is
/// literally in the OCR text of a frame. Model output is never trusted for digits.
enum EvidenceRule {
    static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    static func normalized(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Number-like runs, ranges split ("7:30-20:00" → "7:30", "20:00"). `inRange` marks parts
    /// of a range, which are opening hours and must be checked even when short ("9-17").
    static func numberRunsDetailed(_ text: String) -> [(run: String, inRange: Bool)] {
        let pattern = #"\+?\d[\d .:\-–]*\d|\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { match -> [(run: String, inRange: Bool)] in
            let parts = ns.substring(with: match.range)
                .components(separatedBy: CharacterSet(charactersIn: "-–"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.map { (run: $0, inRange: parts.count > 1) }
        }
    }

    static func numberRuns(_ text: String) -> [String] { numberRunsDetailed(text).map(\.run) }

    /// Canonical digits: "08:00" → "8", "18.00" → "18", "7:30" → "730", "+358 9 4321" → "35894321".
    static func canonicalNumber(_ run: String) -> String {
        var d = digits(run)
        let isTime = run.contains(":") || run.contains(".")
        if isTime, d.count >= 3, d.hasSuffix("00") { d.removeLast(2) }
        while d.count > 1, d.hasPrefix("0") { d.removeFirst() }
        return d
    }

    /// Every number in `answer` (except `allowed`, e.g. when the frame was seen) must appear in
    /// the OCR text. Short non-time numbers (< 3 digits, e.g. "2 m") are not checked.
    static func numbersSupported(in answer: String, ocr: String, allowed: Set<String>) -> Bool {
        unsupportedNumbers(in: answer, ocr: ocr, allowed: allowed).isEmpty
    }

    /// Numbers in `answer` that the OCR text does not contain (see `numbersSupported`).
    static func unsupportedNumbers(in answer: String, ocr: String, allowed: Set<String>) -> [String] {
        let ocrNumbers = numberRuns(ocr).map(canonicalNumber)
        let ocrDigits = digits(ocr)
        var missing: [String] = []
        for (run, inRange) in numberRunsDetailed(answer) {
            let isTime = inRange || run.contains(":") || run.contains(".")
            let n = canonicalNumber(run)
            guard isTime || n.count >= 3, !allowed.contains(n) else { continue }
            // Short numbers must match a whole OCR number ("9" is inside every phone number);
            // long ones (phones) may span OCR's own spacing.
            let supported = ocrNumbers.contains(n)
                || (n.count >= 4 && (ocrDigits.contains(n) || ocrDigits.contains(digits(run))))
            if !supported { missing.append(run) }
        }
        return missing
    }

    /// A quote backs the answer when every number in it is in `text` and at least 80 % of its
    /// words (3+ letters) are: the model may drop labels in between (e.g. "(other, center,
    /// near)") or join two reads, but it cannot invent content.
    static func quoteSupported(_ quote: String, in text: String) -> Bool {
        if supports(quote, in: text) { return true }
        let textDigits = digits(text)
        for run in numberRuns(quote) where digits(run).count >= 2 {
            guard textDigits.contains(digits(run)) else { return false }
        }
        let quoteWords: [String] = words(quote).split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !quoteWords.isEmpty else { return false }
        let textWords: Set<String> = Set(words(text).split(separator: " ").map(String.init))
        let found = quoteWords.filter { textWords.contains($0) }.count
        return Double(found) >= 0.8 * Double(quoteWords.count)
    }

    /// Letters/digits only, lower-cased, accent-folded, single spaces ("NOT LENAC | EUROP" → "not lenac europ").
    static func words(_ s: String) -> String {
        String(normalized(s).map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// Is `value` supported by `ocr`? A multi-line quote ("A | B | C", "A\nB") is checked part
    /// by part; numbers must match digit-for-digit, words ignoring punctuation and case.
    static func supports(_ value: String, in ocr: String) -> Bool {
        let parts = value.components(separatedBy: CharacterSet(charactersIn: "|\n;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        if parts.count > 1 { return parts.allSatisfy { supports($0, in: ocr) } }
        let part = parts[0]
        let d = digits(part)
        if d.count >= 3 {
            return digits(ocr).contains(d)
        }
        let v = words(part)
        return !v.isEmpty && words(ocr).contains(v)
    }

}
