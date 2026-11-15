import Foundation

/// Prompts and schemas of Muisti Turva. English, generic, no examples copied into outputs.
enum SafetyPrompts {
    // MARK: Frame → watched objects

    static let observeSystem = """
    You check one first-person frame from smart glasses for a short list of watched objects \
    that the user asked Muisti to keep an eye on, and for household hazards. Faces are blurred on purpose.

    Report only what is visible in THIS frame. Never guess, never describe people.
    - room: where the wearer is, judged from this frame (kitchen, bathroom, bedroom, \
    living_room, hallway, outside, store, other, unknown).
    - hands_visible: true if the wearer's own hands are in view.
    - objects: one entry per watched object name, using the name exactly as given. visible = \
    whether it is in this frame. state = what this frame shows about it:
      * cooking hobs and stoves: "on" only with a visible heat cue (lit power-level digits or \
    indicator lights on the hob's zones, a red-glowing zone, a gas flame, a knob clearly turned \
    to a heat setting, a boiling pot on a lit zone); "off" only when the controls are clearly \
    visible and show off; anything else "unknown". No cue visible means "unknown", never "off". \
    A clock or timer display (a time like 12:46) and lights on the cooker hood, oven or other \
    appliances are not a heat cue.
      * doors and locks: open / closed / locked / unlocked, only if clearly shown.
      * small things (keys, wallet, medication box, phone): "in_hand" if the wearer holds it, \
    "placed" if it lies somewhere, with location_hint saying where in plain words ("on the \
    kitchen table, next to a blue box").
      * a medication name in the list ("medication:<name>") matches only a box, blister or \
    bottle whose printed name you can read as that name.
      * an object shown on a TV, poster, ad or screen is NOT the real object: visible = false.
      * anything you cannot tell: "unknown".
    evidence: a few words naming the visible cue ("zone 2 display shows 7", "keys in right \
    hand"). For invisible objects use "".
    - actions: what the wearer is doing in this frame to a watched object: turned_on, \
    turned_off, took (swallowing or taking a pill out to take it), locked, unlocked, picked_up, \
    put_down. Empty list if nothing is clearly happening.
    - hazards: also look, on your own, for anything in this frame that could hurt someone or damage the home if it is left like that or is happening now, whether or not it is watched: a cooking hob, oven, iron, heater, hair straightener or other heat source switched on, a burning candle or open flame, smoke, a pot boiling over or a smoking pan, water running or overflowing, a door or window left open, an appliance sparking, a knife or medicine within a child's reach, a dangerous action by the wearer. Name each with a short English noun ("stove", "iron", "candle", "tap", "front door"); use the watched name when it is the same thing. state: its state in a word (on, burning, running, open, smoking …). active: true if it is risky should it stay like this. immediate: true only for danger happening now (smoke, fire outside a hob, boiling over, sparks). Same strict cues as for watched objects: a hob, oven or appliance with no visible heat cue (no flame, no glowing zone, no lit power-level digits) is not a hazard, and a clock or timer display is never a heat cue. Things on a screen or poster do not count. When unsure, leave it out. Empty list if none.
    - label: only if allergens are watched and a food or drink package is in view (null \
    otherwise). product: its name. If the ingredient list is readable: ingredients_visible \
    true, source "ingredients", and which watched allergens the ingredient text contains (in \
    any language, or as an ingredient derived from it). \
    If only the front is visible: ingredients_visible false, source "front", and the watched \
    allergens the front clearly shows (in the product name or flavour, or a picture of the \
    food itself on the package). evidence: the words or \
    picture you based it on. Never guess an allergen that nothing in the frame shows.
    """

    static let observeSchema = #"""
    {"type":"object","properties":{
      "room":{"type":"string","enum":["kitchen","bathroom","bedroom","living_room","hallway","outside","store","other","unknown"]},
      "hands_visible":{"type":"boolean"},
      "objects":{"type":"array","maxItems":12,"items":{"type":"object","properties":{
        "name":{"type":"string"},
        "visible":{"type":"boolean"},
        "state":{"type":"string","enum":["on","off","open","closed","locked","unlocked","in_hand","placed","unknown"]},
        "location_hint":{"type":["string","null"]},
        "evidence":{"type":"string"}},
        "required":["name","visible","state","location_hint","evidence"]}},
      "actions":{"type":"array","maxItems":6,"items":{"type":"object","properties":{
        "object":{"type":"string"},
        "action":{"type":"string","enum":["turned_on","turned_off","took","locked","unlocked","picked_up","put_down"]}},
        "required":["object","action"]}},
      "hazards":{"type":"array","maxItems":6,"items":{"type":"object","properties":{
        "object":{"type":"string"},
        "state":{"type":"string"},
        "active":{"type":"boolean"},
        "immediate":{"type":"boolean"},
        "location_hint":{"type":["string","null"]},
        "evidence":{"type":"string"}},
        "required":["object","state","active","immediate","location_hint","evidence"]}},
      "label":{"anyOf":[{"type":"null"},{"type":"object","properties":{
        "product":{"type":["string","null"]},
        "ingredients_visible":{"type":"boolean"},
        "source":{"type":"string","enum":["ingredients","front"]},
        "allergens_found":{"type":"array","maxItems":12,"items":{"type":"string"}},
        "evidence":{"type":"string"}},
        "required":["product","ingredients_visible","source","allergens_found","evidence"]}]}},
     "required":["room","hands_visible","objects","actions","hazards","label"]}
    """#

    /// Added to the look when several frames go in one picture.
    static func stripNote(frames: Int, seconds: Int) -> String {
        """


        You are shown \(frames) frames from the last \(seconds) seconds in time order, 1 (oldest) to \
        \(frames) (now): either as \(frames) pictures in that order, or as one sheet with the frames numbered. States, the room and the text below are those of the last \
        frame. Use the earlier frames for what was done: report an action only when the frames \
        show it happening — the same object in one state and then the other with the user's hand \
        on it (a knob turned, a switch flipped, a door locked), or something taken from where it \
        was (a pill leaving its blister and going to the mouth). An object that merely looks \
        different in two frames because the view moved is not an action.
        """
    }

    static func observeUser(watched: [String], allergens: [String], ocr: String) -> String {
        """
        Watched objects: \(watched.isEmpty ? "(none)" : watched.joined(separator: ", "))
        Watched allergens: \(allergens.isEmpty ? "(none)" : allergens.joined(separator: ", "))
        Text read on the phone (OCR, may be partial):
        \(ocr.isEmpty ? "(none)" : String(ocr.prefix(1500)))
        """
    }

    // MARK: Memory record → rule (text only)

    static let matchSystem = """
    You check one memory record against one of the user's safety rules. The record is what a \
    vision model and OCR understood from a frame the user's camera glasses saw (type, name, \
    caption, visual details, text read on it). Decide whether the record clearly shows what the \
    rule is about: for an allergen, a food or drink whose ingredient text contains it (in any \
    language, or as an ingredient derived from it), or whose \
    name, flavour or package picture clearly shows it; for another object, that object itself \
    being there. Something only pictured on a poster, screen or advert is not a product in \
    front of the user. Never guess: if the record does not clearly show it, matches is false.
    Output one JSON object: {"matches": boolean, "product": string or null (the product or \
    thing), "found": [the allergens or objects of the rule it shows], "from_ingredients": true \
    only if an ingredient list was read, "evidence": short words from the record}.
    """

    static let matchSchema = #"""
    {"type":"object","properties":{
      "matches":{"type":"boolean"},
      "product":{"type":["string","null"]},
      "found":{"type":"array","maxItems":8,"items":{"type":"string"}},
      "from_ingredients":{"type":"boolean"},
      "evidence":{"type":"string"}},
     "required":["matches","product","found","from_ingredients","evidence"]}
    """#

    struct Match: Decodable, Sendable {
        let matches: Bool
        let product: String?
        let found: [String]
        let from_ingredients: Bool
        let evidence: String
    }

    // MARK: Rules inside the answer call

    /// Call 2 (answering from memory): how to talk about the safety status and log.
    static let statusRules = """

    SAFETY STATUS (Muisti Turva). Questions about the rules or about watched objects ("did I turn \
    off the stove?", "did I take my medicine today?", "what rules do I have?") are answered from \
    the safety status and log in the message. Say \
    what was SEEN and when ("I last saw the stove on at 18:42 and did not see you turn it \
    off"); never "the stove is on" or "you are safe". If the log entry came from the user's own \
    words, say so ("you told me at 19:05 that you turned it off; I did not see it"). Times you \
    state must be copied from the log.
    """

    /// How to fill the `rule` argument of the `create_rule` tool (part of its description).
    static let ruleGuide = """
    The "rule" object:
    - watch: canonical English names of the objects to watch: "stove", "keys", "wallet", \
    "door_lock", "medication:<name the user gives or the box shows>", "allergen:<allergen>". \
    Use exactly the same name in watch, trigger.object, condition.object and in a later \
    log_event call (e.g. "medication:enalapril" everywhere). Names and allergens are English and \
    lower case (milk, gluten, egg, peanut, soy, fish, nuts) whatever language the user speaks.
    - trigger.type:
      * "context" with event "left_home" or "arrived_home";
      * "schedule" with time "HH:mm" (24 h) and grace_min (how long after that time to check);
      * "event" with object (the watched object, or "label" for product labels) and optional \
    state (e.g. "in_hand");
      * "inactivity" with object, state and minutes (e.g. stove on and not looked at for 20).
    - condition (all fields optional, null when unused):
      * object + last_state (+ not_followed_by): e.g. stove, "on", "off" = last seen on and \
    not seen turned off;
      * action (+ count_at_least, within_min): the action must NOT have happened in the window \
    when count_at_least is null (medicine not taken), or must have happened at least that many \
    times (already taken: second dose guard); window = within_min minutes, or today if null;
      * seen_within_min: object seen in the last N minutes (keys at home);
      * allergens: allergens to look for on labels.
    - severity: "high" for fire, medicine and allergen rules, else "medium".
    - message: the spoken warning in the user's language, saying only what was seen, with \
    placeholders {last_seen_time}, {place}, {action_time}, {allergens}, {product} that the app \
    fills in ("I last saw the stove on at {last_seen_time} and did not see you turn it off."). \
    Never give medical or dosage advice.
    - summary: the rule in one sentence in the user's language. cooldown_min: 30 unless asked.
    - confirm_question: for rules about an action only the user can confirm (taking a medicine), the question Muisti will ask later when it sees the box in the user's hand, asking whether they just did it ("Did you just take your Enalapril?"), in the user's language; else null. It is NOT the "is that right?" of the read-back.
    - A medicine reminder ("my blood pressure pill every morning at 8") becomes a schedule rule \
    with condition action "took" on that medication (count_at_least null). If the user also \
    wants protection from a second dose, that is a separate event rule; create only what they \
    asked for.
    """

    static let ruleSchema = #"""
    {"anyOf":[{"type":"null"},{"type":"object","properties":{
      "summary":{"type":"string"},
      "watch":{"type":"array","maxItems":6,"items":{"type":"string"}},
      "trigger":{"type":"object","properties":{
        "type":{"type":"string","enum":["context","schedule","event","inactivity"]},
        "event":{"type":["string","null"],"enum":["left_home","arrived_home",null]},
        "time":{"type":["string","null"]},
        "grace_min":{"type":["integer","null"]},
        "object":{"type":["string","null"]},
        "state":{"type":["string","null"]},
        "minutes":{"type":["integer","null"]}},
        "required":["type","event","time","grace_min","object","state","minutes"]},
      "condition":{"type":"object","properties":{
        "object":{"type":["string","null"]},
        "last_state":{"type":["string","null"]},
        "not_followed_by":{"type":["string","null"]},
        "action":{"type":["string","null"]},
        "count_at_least":{"type":["integer","null"]},
        "within_min":{"type":["integer","null"]},
        "seen_within_min":{"type":["integer","null"]},
        "allergens":{"type":["array","null"],"items":{"type":"string"}}},
        "required":["object","last_state","not_followed_by","action","count_at_least","within_min","seen_within_min","allergens"]},
      "severity":{"type":"string","enum":["high","medium","low"]},
      "message":{"type":"string"},
      "cooldown_min":{"type":"integer"},
      "confirm_question":{"type":["string","null"]}},
     "required":["summary","watch","trigger","condition","severity","message","cooldown_min","confirm_question"]}]}
    """#

    /// `ruleSchema` without the null alternative (a tool argument is always an object).
    static var ruleObjectSchema: String {
        guard let root = try? JSONSerialization.jsonObject(with: Data(ruleSchema.utf8)) as? [String: Any],
              let object = (root["anyOf"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "object" }),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return "{\"type\":\"object\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    static let eventSchema = #"""
    {"anyOf":[{"type":"null"},{"type":"object","properties":{
      "object":{"type":"string"},
      "kind":{"type":"string","enum":["action","state"]},
      "value":{"type":"string"}},
     "required":["object","kind","value"]}]}
    """#
}
