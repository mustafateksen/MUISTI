import Foundation

// MARK: - Extraction (frame → structured record)

struct ExtractedRecord: Codable, Sendable {
    var kind: String?
    var name: String?
    var phone: String?
    var hours: String?
    var other_text: String?
    var caption: String?
    var keywords: [String]?
    var confidence: Double?
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
