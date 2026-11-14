import Foundation

// MARK: - Extraction (frame → structured record)
//
// Prompt and checks adapted from the team's v12 extraction prompt (object test set: 93 %
// coverage, 91 % precision; glasses Q&A 30-31/31, nothing invented). Their keyword-based
// object clean-ups (screen→sign on "neon", dropping "mascot" statues, plural→singular) are
// left out on purpose: the prompt's definitions carry that, no case-specific code. No few-shot examples: they steered the model
// toward the example cases (a restaurant frame came back with the dentist example's caption);
// the JSON schema fixes the output shape instead. The model cites the
// OCR line every literal came from; code then checks each literal against that line, because
// the prompt alone did not stop the model from reading text that OCR never saw.
//
// Model output is decoded leniently: numbers may come back as strings and vice versa, lists
// as a single string. A strict decoder turned good answers into failures.

struct ExtractedRecord: Codable, Sendable {
    struct Item: Codable, Sendable { var label: String; var value: String; var line: String? }
    struct Scene: Codable, Sendable { var place_type: String?; var indoor: Bool?; var lighting: String? }
    struct SeenObject: Codable, Sendable {
        var name: String
        var category: String?
        var position: String?
        var distance: String?
        var details: String?
        var count: Int?
        /// "clear" | "partial" | "unsure"; code also marks late or far list entries unsure.
        var visibility: String?
        var isUnsure: Bool { visibility == "unsure" }
    }
    struct Relation: Codable, Sendable { var subject: String; var relation: String; var object: String }
    struct Depiction: Codable, Sendable {
        var medium: String?
        var on: String?
        var content: String
        var depicted: [String]?
    }

    var useful: Bool?
    var kind: String?
    var subtype: String?
    var name: String?
    var name_line: String?
    var phone: String?
    var phone_line: String?
    var hours: String?
    var hours_line: String?
    var items: [Item]
    var other_text: String?
    var scene: Scene?
    var objects: [SeenObject]
    var relations: [Relation]
    var depictions: [Depiction]
    var caption: String?
    var keywords: [String]?
    var confidence: Double?
    /// Whether the frame holds something the wearer may need to be told or reminded of
    /// (`MemoryPrompts.extractionSchema`); read by the agent, not stored.
    var attention: String?
    var attention_reason: String?
    /// The unified frame analysis (pipeline v2, §3.1): the state of things that can be on or
    /// open, allergens named on what is in view, what a hand is doing, landmarks for finding
    /// the way back indoors, and what the wearer holds or has put down. The same call as the
    /// rest; the safety side reads them for frames it did not look at itself.
    struct ObjectStateSeen: Codable, Sendable { var object: String; var state: String; var evidence: String? }
    struct AllergenSeen: Codable, Sendable { var allergen: String; var `where`: String?; var quote: String? }
    struct ActionSeen: Codable, Sendable { var action: String; var object: String; var confidence: Double? }
    struct Landmark: Codable, Sendable { var kind: String; var text: String?; var direction: String? }
    var object_states: [ObjectStateSeen] = []
    var allergens_seen: [AllergenSeen] = []
    var actions: [ActionSeen] = []
    var landmarks: [Landmark] = []
    var hold_items: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useful = c.lenientBool(.useful)
        kind = c.lenientString(.kind)
        subtype = c.lenientString(.subtype)
        name = c.lenientString(.name)
        name_line = c.lenientString(.name_line)
        phone = c.lenientString(.phone)
        phone_line = c.lenientString(.phone_line)
        hours = c.lenientString(.hours)
        hours_line = c.lenientString(.hours_line)
        items = (try? c.decodeIfPresent([Item].self, forKey: .items)) ?? []
        other_text = c.lenientString(.other_text)
        scene = try? c.decodeIfPresent(Scene.self, forKey: .scene)
        objects = (try? c.decodeIfPresent([SeenObject].self, forKey: .objects)) ?? []
        relations = (try? c.decodeIfPresent([Relation].self, forKey: .relations)) ?? []
        depictions = (try? c.decodeIfPresent([Depiction].self, forKey: .depictions)) ?? []
        caption = c.lenientString(.caption)
        attention = c.lenientString(.attention)
        attention_reason = c.lenientString(.attention_reason)
        object_states = (try? c.decodeIfPresent([ObjectStateSeen].self, forKey: .object_states)) ?? []
        allergens_seen = (try? c.decodeIfPresent([AllergenSeen].self, forKey: .allergens_seen)) ?? []
        actions = (try? c.decodeIfPresent([ActionSeen].self, forKey: .actions)) ?? []
        landmarks = (try? c.decodeIfPresent([Landmark].self, forKey: .landmarks)) ?? []
        hold_items = c.lenientStrings(.hold_items) ?? []
        keywords = c.lenientStrings(.keywords)
        confidence = c.lenientDouble(.confidence)
    }

    /// What the place or thing is: the specific type ("cafe"), else the broad category.
    /// The broad category ("restaurant" also covers cafés) only goes into the search keywords,
    /// so the answer model never calls a café a restaurant because of it.
    var kindLabel: String? {
        [subtype, kind].compactMap { $0 }.first { !$0.isEmpty }
    }

    var searchKeywords: [String] {
        (keywords ?? []) + [kind].compactMap { $0 }
    }

    /// Labelled text of everything visual, stored with the record for search, the reranker
    /// and the answer model. Pictures are marked so they are never taken for real things.
    var visualText: String? {
        var lines: [String] = []
        if let scene, let place = scene.place_type {
            let extra = [scene.indoor.map { $0 ? "indoor" : "outdoor" }, scene.lighting].compactMap { $0 }
            lines.append("Scene: \(place)" + (extra.isEmpty ? "" : " (\(extra.joined(separator: ", ")))"))
        }
        if !items.isEmpty {
            lines.append("Rows on sign: " + items.map { "\($0.label) → \($0.value)" }.joined(separator: "; "))
        }
        if !objects.isEmpty {
            lines.append("Visible things: " + objects.map { o in
                var s = o.name
                let meta = [o.category, o.position, o.distance].compactMap { $0 }
                if !meta.isEmpty { s += " (\(meta.joined(separator: ", ")))" }
                if let count = o.count, count > 1 { s += " ×\(count)" }
                if let details = o.details, !details.isEmpty { s += ": \(details)" }
                if o.isUnsure { s += " [unsure]" }
                return s
            }.joined(separator: "; "))
        }
        if !relations.isEmpty {
            lines.append("Spatial: " + relations.map { "\($0.subject) \($0.relation) \($0.object)" }.joined(separator: "; "))
        }
        for d in depictions {
            var s = "PICTURE (not a real object): \(d.content)"
            if let on = d.on { s += ". Shown on: \(on)" + (d.medium.map { " (\($0))" } ?? "") }
            lines.append(s)
        }
        let states = object_states.filter { $0.state != "unknown" }
        if !states.isEmpty {
            lines.append("States: " + states.map { "\($0.object) \($0.state)" + ($0.evidence.map { $0.isEmpty ? "" : " (\($0))" } ?? "") }.joined(separator: "; "))
        }
        if !actions.isEmpty {
            lines.append("Being done: " + actions.map { "\($0.action.replacingOccurrences(of: "_", with: " ")) \($0.object)" }.joined(separator: "; "))
        }
        if !allergens_seen.isEmpty {
            lines.append("Allergens named: " + allergens_seen.map { "\($0.allergen)" + ($0.where.map { " (\($0))" } ?? "") + ($0.quote.map { " “\($0)”" } ?? "") }.joined(separator: "; "))
        }
        if !landmarks.isEmpty {
            lines.append("Landmarks: " + landmarks.map { "\($0.kind.replacingOccurrences(of: "_", with: " "))" + ($0.text.map { " “\($0)”" } ?? "") + ($0.direction.map { " (\($0))" } ?? "") }.joined(separator: "; "))
        }
        if !hold_items.isEmpty { lines.append("In hand or just put down: " + hold_items.joined(separator: ", ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Code-side checks on the model's record (the prompt alone is not enough).
enum ExtractionCheck {
    /// OCR rows as the model sees them: "L01 …".
    static func ocrLines(_ ocr: String) -> String {
        let rows = rows(ocr)
        guard !rows.isEmpty else { return "OCR_LINES:\n(none)" }
        return "OCR_LINES:\n" + rows.enumerated().map { String(format: "L%02d ", $0.offset + 1) + $0.element }.joined(separator: "\n")
    }

    static func rows(_ ocr: String) -> [String] {
        ocr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// - name / phone / hours must be found on their cited OCR line (a name may run over the
    ///   next 2 lines); numbers must match exactly, letters tolerate small OCR errors.
    /// - items: label and value on the same cited line.
    /// - objects ≤ 15, count 1…50; relations only between listed objects.
    static func verify(_ record: ExtractedRecord, ocr: String) -> ExtractedRecord {
        let rows = rows(ocr)
        var r = record
        if let name = r.name, !found(name, rows, line: r.name_line, span: 3) { r.name = nil; r.name_line = nil }
        if let phone = r.phone, !found(phone, rows, line: r.phone_line, span: 1) { r.phone = nil; r.phone_line = nil }
        if let hours = r.hours, !found(hours, rows, line: r.hours_line, span: 1) { r.hours = nil; r.hours_line = nil }
        r.items = r.items.filter { item in
            guard let line = item.line, let i = index(line), rows.indices.contains(i) else { return false }
            return matches(item.label, rows[i]) && matches(item.value, rows[i])
        }
        // Uncertain objects (Ömer's measured rule, v18): the model's own "unsure", or late in
        // the list (9th+), or 5th+ and far away. Kept, but marked: the answer model treats them
        // as "may have been there". Precision 84.5% → 87–89% on his 53-frame set.
        r.objects = Array(r.objects.prefix(15)).enumerated().map { i, o in
            var o = o
            o.count = min(50, max(1, o.count ?? 1))
            o.visibility = o.visibility?.lowercased()
            if let v = o.visibility, v != "clear", v != "partial" { o.visibility = "unsure" }
            if i >= 8 || (i >= 4 && o.distance == "far") { o.visibility = "unsure" }
            return o
        }
        let names = Set(r.objects.map { EvidenceRule.words($0.name) })
        r.relations = r.relations.filter { names.contains(EvidenceRule.words($0.subject)) && names.contains(EvidenceRule.words($0.object)) }
        return r
    }

    private static func found(_ value: String, _ rows: [String], line: String?, span: Int) -> Bool {
        guard let line, let start = index(line), rows.indices.contains(start) else {
            // No (valid) line cited: accept only if the value is somewhere in the OCR, strictly.
            return EvidenceRule.supports(value, in: rows.joined(separator: "\n"))
        }
        let window = rows[start..<min(rows.count, start + span)].joined(separator: " ")
        return matches(value, window)
    }

    /// "L03" → 2.
    private static func index(_ id: String) -> Int? {
        Int(id.filter(\.isNumber)).map { $0 - 1 }
    }

    /// Every number of `value` appears exactly in `text` ("5TH" ≠ "7TH"); every word matches a
    /// word of `text` with at most one edit for words of 5+ letters (OCR noise).
    static func matches(_ value: String, _ text: String) -> Bool {
        // "Floyd's" / "Flouds": drop apostrophes so a word is not split into "floyd" + "s".
        let value = value.replacingOccurrences(of: "[’'`´]", with: "", options: .regularExpression)
        let text = text.replacingOccurrences(of: "[’'`´]", with: "", options: .regularExpression)
        let textNumbers = Set(EvidenceRule.numberRuns(text).map(EvidenceRule.digits))
        let textDigits = EvidenceRule.digits(text)
        for run in EvidenceRule.numberRuns(value) {
            let d = EvidenceRule.digits(run)
            guard textNumbers.contains(d) || (d.count >= 4 && textDigits.contains(d)) else { return false }
        }
        let textWords = EvidenceRule.words(text).split(separator: " ").map(String.init)
        let valueWords = EvidenceRule.words(value).split(separator: " ").map(String.init).filter { !$0.allSatisfy(\.isNumber) }
        guard !valueWords.isEmpty || !EvidenceRule.numberRuns(value).isEmpty else { return false }
        return valueWords.allSatisfy { w in
            textWords.contains { t in t == w || (w.count >= 5 && t.count >= 4 && editDistance(t, w) <= 1) }
        }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension MemoryPrompts {
    static let extractionSystem = """
    You turn photos from smart glasses into memory records, so the wearer can later ask \
    "where did I see X?" about ANYTHING useful they walked past, not only text.

    You get the image and OCR_LINES: text read by a separate OCR engine, one line per visual \
    row, each with an id (L01, L02, ...). OCR may contain small errors. OCR_LINES may be "(none)".

    TEXT rules (strict):
    - name, phone, hours, items and other_text must come from OCR_LINES. Put the id of the line \
    where a value starts in the matching *_line field (or "line" for items). A name may continue \
    over the next 1-2 lines; phone, hours and items must be on one line.
    - If OCR_LINES does not contain it, use null. Do NOT read text from the image that is missing \
    from OCR_LINES.
    - other_text: remaining useful text from OCR_LINES (slogan, website, address, date, price), \
    joined with " / ".
    - items: label -> value pairs (directory floors, menu prices) ONLY when both are on the SAME line.

    VISUAL rules:
    - objects: describe the scene so that ANY clearly visible thing can be found again later. \
    List 8-15 objects. Go through these groups and include what is clearly visible from each \
    (largest / most useful first):
      1. ways to move: stairs, escalator, elevator, door, entrance, exit, crosswalk, ramp, bridge
      2. structures and landmarks: building (say what kind in details: mall, office tower, shop \
    front), store, statue, crane, scaffolding, column, arch, fountain, aquarium, slide, stage
      3. vehicles: car, taxi, bus, bicycle, pedicab, scooter, truck
      4. furniture and amenities: bench, chair, table, sofa, counter, trash bin, ashtray, \
    umbrella, chandelier, lamp, street lamp, railing, kiosk, vending machine, ATM
      5. signs and media: sign, screen, billboard, poster, banner, flag, traffic light, QR code
      6. nature: tree, plant, flower, water
      7. goods on display: mannequin, clothing rack, display case, hat, shoe, fish
      Use these words exactly when they fit:
        screen = an electronic display showing video or changing images (TV, LED wall, monitor, \
    digital billboard).
        sign = fixed lettering or a logo, lit or not (shop sign, neon sign, store name). A lit \
    sign is NOT a screen.
        billboard = a large printed or digital advertisement panel on a building or pole.
        poster = a printed picture or advert on a wall, window or stand. banner = hanging \
    fabric/vinyl.
      For each: name (simple English noun, singular), category, position in the frame \
    (left/center/right), distance (near/mid/far), details (at most 12 words: colour, material, \
    kind, state, what is on it), count (how many of this thing are visible in THIS frame), \
    visibility ("clear": plainly visible and surely this thing; "partial": cut off or partly \
    hidden but surely this thing; "unsure": you are not sure what it is or whether it is there). \
    List the clearest things first.
      Numbers on plaques, indicators and screens: say in details what the number MEANS only if \
    it is clear (e.g. "elevator position indicator showing 4", "floor label 5TH FLOOR at top of \
    directory"). If you cannot tell what a number means, write "unlabeled number 4". Never \
    decide which floor the viewer is on.
      Only list things you can actually see.
      People are never objects, including costumed performers, mascots and "living statues" \
    (a person dressed as a statue is a person). A real statue is stone or metal on a pedestal.
      Every shop front you can see counts as a store (put what it sells in details). A small \
    street booth selling snacks, drinks or newspapers is a kiosk. Name the goods on stalls and in \
    windows (fish, flowers, hats, shoes).
      A QR code on a banner, poster, screen or sign is its own object: list it as "qr code" \
    (details: what it is on).
      Rare or striking things (aquarium, fountain, statue, slide, stage) only if you are certain: \
    a blue wall, tiles or a screen showing water is not an aquarium.
    - relations (max 6): spatial facts between listed objects that help someone find them, e.g. "stairs" \
    "behind" "directory screen", "ashtray" "next to" "door". Use simple relations: behind, in \
    front of, left of, right of, next to, above, below, on, inside.
    - scene: place_type (e.g. event hall, corridor, elevator lobby, street, cafe, entrance), \
    indoor true/false, lighting (bright/dim/dark/colored).
    - Never describe real people in the scene, their faces, clothing or body, and never license \
    plates. People are not objects.

    PICTURES (depictions), kept apart from the real scene:
    - Banners, posters, screens, billboards and signs often SHOW pictures: a photo of a man at a \
    desk, a car, a beach, a product. Things inside a picture are NOT physically there. Never put \
    them in objects or relations.
    - For each picture you can make out (max 4, largest first), add one depictions item: medium \
    (banner/poster/screen/sign/billboard/painting/other), on (which real object or booth it is \
    on), content (at most 15 words: what the picture shows), depicted (simple nouns of what is in it).
    - People INSIDE pictures may be described generically (a man, a team; what they are doing). \
    Never guess who they are.
    - The banner/screen itself still goes in objects; only its picture content goes in \
    depictions. Text on it stays in the TEXT fields.

    OTHER:
    - kind must be one of: booth, shop, restaurant, health, service, directory, event, transport, \
    notice, street, indoor_space, other. Use street / indoor_space when there is no business or \
    sign. The specific type goes in subtype (e.g. dentist, pharmacy, cafe, bus stop).
    - caption: 1-2 English sentences describing the place and the most useful things in it. Never \
    mention languages or text you cannot read.
    - keywords: up to 10 search terms for what this is, in English, Finnish and Turkish \
    (e.g. dentist, hammaslääkäri, dişçi), so it can be found in any of these languages.
    - useful=false only if the frame shows nothing worth remembering (blurred, floor, ceiling, \
    a close-up of a person).
    - confidence: 0..1, how legible and certain the record is.
    - attention: whether this frame holds something a person walking here might need to be told \
    now or reminded of later, beyond simply remembering the place: "warning" (a danger or \
    prohibition that applies to someone passing: wet floor, closed path, do not enter), \
    "time_limited" (a closing time, deadline, parking limit, last departure, expiry date), \
    "schedule" (a timetable, departure board, opening days), "price" (a price of a product or \
    service), "event" (a dated event on a poster or screen), "document" (a ticket, receipt, \
    card, code, room or booking number), "person_badge" (a name badge or business card), "personal" (a \
    thing people own, take or can forget, seen up close: medicine in any form — a box, blister, \
    bottle or pills; keys, a wallet, a phone, glasses, a bag, an umbrella; or something at home \
    that is on or open: a lit stove or hob, an iron, a running tap, an open door or window); \
    otherwise "none", which is the usual answer. attention_reason: what exactly, in one short \
    English sentence, quoting the text it rests on; null when attention is "none".
    - object_states: only for things in view that can be on or off, open or closed, locked or \
    unlocked (a stove or hob, an oven, an iron, a tap, a door, a window, a fridge door, a lock, \
    a light): the thing, its state as it looks in this frame ("unknown" when it cannot be told), \
    and the few words of what shows it (a blue flame, a glowing ring, the knob position). A \
    thing shown on a screen or a picture is not listed. Usually [].
    - allergens_seen: food allergens named on a product, label, menu or plate in view (milk, egg, \
    nuts, peanut, gluten, wheat, soy, fish, shellfish, sesame, strawberry and the like): the \
    allergen in English, where it is (label, front of package, menu, plate) and the words read, \
    in their own language. Usually [].
    - actions: only what a hand in the frame is plainly doing to a thing right now (turning a \
    knob, locking a door with a key, taking a pill from a blister, putting keys down): a short \
    verb form like "turning", "locking", "taking", "putting_down", the thing, and how sure \
    (0..1). One frame rarely shows an action: usually [].
    - landmarks: what helps to find the way inside a building: exit signs, stairs, lifts, \
    escalators, numbered rooms or gates, toilets signs, with the text on them and the side an \
    arrow or the thing itself is on (left, right, ahead). Usually a few indoors, [] outdoors.
    - hold_items: things held in the hand or just put down within reach (keys, a wallet, a \
    phone, a medicine box with its name). Usually [].

    Return ONLY one JSON object with keys: object_states, allergens_seen, actions, landmarks, hold_items and: useful, kind, subtype, name, name_line, phone, \
    phone_line, hours, hours_line, items, other_text, scene, objects, relations, depictions, \
    caption, keywords, confidence, attention, attention_reason.
    """

    static func extractionUser(ocr: String) -> String { ExtractionCheck.ocrLines(ocr) }

    /// JSON schema for guided decoding (vLLM `response_format: json_schema`).
    static let extractionSchema = #"""
    {"type":"object","properties":{
      "useful":{"type":"boolean"},
      "kind":{"type":["string","null"],"enum":["booth","shop","restaurant","health","service","directory","event","transport","notice","street","indoor_space","other",null]},
      "subtype":{"type":["string","null"]},
      "name":{"type":["string","null"]},"name_line":{"type":["string","null"]},
      "phone":{"type":["string","null"]},"phone_line":{"type":["string","null"]},
      "hours":{"type":["string","null"]},"hours_line":{"type":["string","null"]},
      "items":{"type":"array","maxItems":20,"items":{"type":"object","properties":{"label":{"type":"string"},"value":{"type":"string"},"line":{"type":"string"}},"required":["label","value","line"]}},
      "other_text":{"type":["string","null"]},
      "scene":{"type":"object","properties":{"place_type":{"type":"string"},"indoor":{"type":"boolean"},"lighting":{"type":"string"}},"required":["place_type","indoor","lighting"]},
      "objects":{"type":"array","maxItems":15,"items":{"type":"object","properties":{"name":{"type":"string"},"category":{"type":"string","enum":["navigation","seating","waste_smoking","food_drink","power_tech","sign_screen","furniture","vehicle","nature","building","safety","other"]},"position":{"type":"string","enum":["left","center","right"]},"distance":{"type":"string","enum":["near","mid","far"]},"details":{"type":"string"},"count":{"type":"integer"},"visibility":{"type":"string","enum":["clear","partial","unsure"]}},"required":["name","category","position","distance","details","count","visibility"]}},
      "relations":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"subject":{"type":"string"},"relation":{"type":"string"},"object":{"type":"string"}},"required":["subject","relation","object"]}},
      "depictions":{"type":"array","maxItems":4,"items":{"type":"object","properties":{"medium":{"type":"string","enum":["banner","poster","screen","sign","billboard","painting","other"]},"on":{"type":"string"},"content":{"type":"string"},"depicted":{"type":"array","items":{"type":"string"}}},"required":["medium","on","content","depicted"]}},
      "caption":{"type":"string"},
      "keywords":{"type":"array","maxItems":12,"items":{"type":"string"}},
      "confidence":{"type":"number"},
      "attention":{"type":"string","enum":["none","warning","time_limited","schedule","price","event","document","person_badge","personal"]},
      "attention_reason":{"type":["string","null"]},
      "object_states":{"type":"array","maxItems":5,"items":{"type":"object","properties":{"object":{"type":"string"},"state":{"type":"string","enum":["on","off","open","closed","locked","unlocked","unknown"]},"evidence":{"type":"string"}},"required":["object","state","evidence"]}},
      "allergens_seen":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"allergen":{"type":"string"},"where":{"type":"string","enum":["label","front","menu","plate","shelf","other"]},"quote":{"type":["string","null"]}},"required":["allergen","where","quote"]}},
      "actions":{"type":"array","maxItems":3,"items":{"type":"object","properties":{"action":{"type":"string"},"object":{"type":"string"},"confidence":{"type":"number"}},"required":["action","object","confidence"]}},
      "landmarks":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"kind":{"type":"string","enum":["exit","stairs","elevator","escalator","room_sign","gate","toilet","shop","other"]},"text":{"type":["string","null"]},"direction":{"type":["string","null"],"enum":["left","right","ahead",null]}},"required":["kind","text","direction"]}},
      "hold_items":{"type":"array","maxItems":4,"items":{"type":"string"}}},
     "required":["useful","kind","subtype","name","name_line","phone","phone_line","hours","hours_line","items","other_text","scene","objects","relations","depictions","caption","keywords","confidence","attention","attention_reason","object_states","allergens_seen","actions","landmarks","hold_items"]}
    """#
}

// MARK: - Episode summary (one walk / visit)

struct EpisodeSummary: Codable, Sendable {
    var title: String?
    var summary: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenientString(.title)
        summary = c.lenientString(.summary)
    }
}

extension MemoryPrompts {
    static let episodeSystem = """
    You write the title and summary of one memory episode: a continuous stretch of a walk or a \
    visit, captured by the user's camera glasses. You get the frames in the order they were seen, \
    with what was read on them (OCR) and what a vision model saw.

    - title: 3 to 7 words naming the place or route and its main stops, e.g. "Otaniemi walk: \
    pharmacy, café and dentist" or "Junction hall: NVIDIA stand". Use names exactly as written \
    on the signs.
    - summary: 2 to 4 sentences describing what was seen, in order, and how things were \
    related in space (next to, across, behind, on the same street, inside). Mention places, signs, \
    useful objects and pictures (say when something was only a picture on a banner or screen).
    - Use only the frames. Do not add phone numbers, hours, prices or other numbers: those are \
    kept in the frames themselves. Never describe people.
    - Write in English.

    Output exactly one JSON object and nothing else: {"title": "...", "summary": "..."}
    """

    static let episodeSchema = #"""
    {"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"}},"required":["title","summary"]}
    """#

    static func episodeUser(_ episode: MemoryEpisode, records: [MemoryRecord]) -> String {
        let start = episode.startedAt
        let frames = records.map { r -> String in
            let offset = Int(r.seenAt.timeIntervalSince(start))
            var parts = ["frame at +\(offset / 60)m\(offset % 60)s"]
            if let street = r.street { parts.append("street: \(street)") }
            if let kind = r.kind { parts.append("type: \(kind)") }
            if let name = r.name { parts.append("name on sign: \(name)") }
            if let caption = r.caption { parts.append("caption: \(caption)") }
            if let visual = r.visual { parts.append(visual.replacingOccurrences(of: "\n", with: "; ")) }
            if !r.ocrText.isEmpty { parts.append("OCR: " + r.ocrText.replacingOccurrences(of: "\n", with: " | ")) }
            return "- " + parts.joined(separator: " · ")
        }
        return "Episode with \(records.count) frames:\n" + frames.joined(separator: "\n")
    }
}
