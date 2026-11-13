import Foundation

// MARK: - Extraction (frame → structured record)

// Model output is decoded leniently: numbers may come back as strings and vice versa,
// lists as a single string. A strict decoder turned good answers into failures.

struct ExtractedRecord: Codable, Sendable {
    var kind: String?
    var name: String?
    var phone: String?
    var hours: String?
    var other_text: String?
    var caption: String?
    var keywords: [String]?
    var confidence: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenientString(.kind)
        name = c.lenientString(.name)
        phone = c.lenientString(.phone)
        hours = c.lenientString(.hours)
        other_text = c.lenientString(.other_text)
        caption = c.lenientString(.caption)
        keywords = c.lenientStrings(.keywords)
        confidence = c.lenientDouble(.confidence)
    }
}

// MARK: - Question → search plan

struct QueryPlan: Codable, Sendable {
    var minutes_back: Int?
    var near_me_meters: Int?
    var keywords: [String]
    var wanted: String?          // phone | hours | price | name | location | text | other
    var language: String?        // tr | en | fi …
    var is_forget_command: Bool?
    var forget_minutes: Int?

    init(minutes_back: Int?, near_me_meters: Int?, keywords: [String], wanted: String?, language: String?,
         is_forget_command: Bool?, forget_minutes: Int?) {
        self.minutes_back = minutes_back
        self.near_me_meters = near_me_meters
        self.keywords = keywords
        self.wanted = wanted
        self.language = language
        self.is_forget_command = is_forget_command
        self.forget_minutes = forget_minutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes_back = c.lenientDouble(.minutes_back).map { Int($0) }
        near_me_meters = c.lenientDouble(.near_me_meters).map { Int($0) }
        keywords = c.lenientStrings(.keywords) ?? []
        wanted = c.lenientString(.wanted)
        language = c.lenientString(.language)
        is_forget_command = c.lenientBool(.is_forget_command)
        forget_minutes = c.lenientDouble(.forget_minutes).map { Int($0) }
    }
}

// MARK: - Answer

enum AnswerLabel: String, Codable, Sendable {
    case seen = "GORDUM"
    case unknown = "BILMIYORUM"

    var display: String { self == .seen ? "GÖRDÜM" : "BİLMİYORUM" }
}

struct AnswerDraft: Codable, Sendable {
    var answer: String
    var label: String
    var used_ids: [Int64]?
    var value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let answer = c.lenientString(.answer) else {
            throw DecodingError.keyNotFound(CodingKeys.answer, .init(codingPath: [], debugDescription: "answer"))
        }
        self.answer = answer
        label = c.lenientString(.label) ?? "BILMIYORUM"
        used_ids = c.lenientStrings(.used_ids)?.compactMap { Int64($0.filter(\.isNumber)) }
        value = c.lenientString(.value)
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
    static let extractionSystem = """
    You turn one first-person photo from smart glasses, plus the text the phone already read \
    from it with OCR, into a memory record. Report ONLY what is visible.
    Rules:
    - phone, hours and prices must be copied character-for-character from the OCR text. \
    If they are not in the OCR text, use null.
    - If unsure about any field, use null.
    - Never describe people. Never guess anyone's identity or name.
    - kind: short English noun for the place or object (dentist, cafe, pharmacy, restaurant, \
    shop, stand, sign, poster, menu, bus stop, street sign…) or null.
    - name: the business, brand or stand name as written, or null.
    - other_text: other important visible text, max 200 characters, or null.
    - caption: one short English sentence describing the scene, no people details.
    - keywords: up to 10 search terms covering the kind and name in English, Finnish and \
    Turkish (e.g. dentist, hammaslääkäri, dişçi).
    - confidence: 0..1, how legible and certain the record is.
    Answer with a single JSON object and nothing else:
    {"kind":…,"name":…,"phone":…,"hours":…,"other_text":…,"caption":…,"keywords":[…],"confidence":…}
    """

    static func extractionUser(ocr: String, street: String?, time: String) -> String {
        """
        Seen at: \(time)\(street.map { ", street: \($0)" } ?? "")
        OCR text (verbatim, line by line):
        \(ocr.isEmpty ? "(no text read)" : ocr)
        """
    }

    static let planSystem = """
    You convert a spoken question about things the user saw earlier into a JSON search plan \
    for a local memory database. Output a single JSON object and nothing else:
    {"minutes_back": int or null, "near_me_meters": int or null, "keywords": [..],
     "wanted": "phone"|"hours"|"price"|"name"|"location"|"text"|"other"|null,
     "language": ISO 639-1 code of the question,
     "is_forget_command": bool, "forget_minutes": int or null}
    - minutes_back: how far back to search. "just now/az önce" ≈ 15, "this morning/bu sabah" = \
    minutes since 06:00 today, "today/bugün" = minutes since 00:00, unspecified = null (all).
    - near_me_meters: only if the question refers to here / this street / nearby (≈300), else null.
    - keywords: 4–12 search terms for what is being looked for, with synonyms in English, \
    Finnish and Turkish (dişçi → dentist, hammaslääkäri, dental, dişçi). No stop words.
    - is_forget_command: true if the user asks to forget/delete recent memories \
    ("son 10 dakikayı unut"), with forget_minutes.
    """

    static func planUser(question: String, now: String) -> String {
        "Now: \(now)\nQuestion: \(question)"
    }

    static func answerSystem(language: String) -> String {
        """
        You answer the user's question ONLY from the memory records below. Each record is \
        something the user's glasses saw, with the exact OCR text read from the frame.
        Rules:
        - Phone numbers, opening hours and prices may ONLY be given if they appear in a \
        record's ocr_text. Copy them exactly.
        - If the answer is not in the records, say you did not see it clearly. Never guess.
        - Mention when and where it was seen if helpful (use the given local time and street).
        - Keep the answer to one or two short spoken sentences, in language "\(language)".
        Output a single JSON object and nothing else:
        {"answer": "...", "label": "GORDUM" or "BILMIYORUM", "used_ids": [record ids], \
        "value": the exact literal you quoted (phone/hours/price) or null}
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
        let ocrNumbers = numberRuns(ocr).map(canonicalNumber)
        let ocrDigits = digits(ocr)
        for (run, inRange) in numberRunsDetailed(answer) {
            let isTime = inRange || run.contains(":") || run.contains(".")
            let n = canonicalNumber(run)
            guard isTime || n.count >= 3, !allowed.contains(n) else { continue }
            // Short numbers must match a whole OCR number ("9" is inside every phone number);
            // long ones (phones) may span OCR's own spacing.
            let supported = ocrNumbers.contains(n)
                || (n.count >= 4 && (ocrDigits.contains(n) || ocrDigits.contains(digits(run))))
            if !supported { return false }
        }
        return true
    }

    /// Is `value` supported by `ocr`?
    static func supports(_ value: String, in ocr: String) -> Bool {
        let d = digits(value)
        if d.count >= 3 {
            return digits(ocr).contains(d)
        }
        let v = normalized(value)
        return !v.isEmpty && normalized(ocr).contains(v)
    }

    /// Drops extracted literals that the OCR text does not contain.
    static func clean(_ record: ExtractedRecord, ocr: String) -> ExtractedRecord {
        var r = record
        if let phone = r.phone, !supports(phone, in: ocr) { r.phone = nil }
        if let hours = r.hours, !supports(hours, in: ocr) { r.hours = nil }
        return r
    }
}
