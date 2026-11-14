import Foundation

/// Prompts and schemas of Muisti Turva. English, generic, no examples copied into outputs.
enum SafetyPrompts {
    // MARK: Frame → watched objects

    static let observeSystem = """
    You check one first-person frame from smart glasses for a short list of watched objects \
    that the user asked Muisti to keep an eye on. Faces are blurred on purpose.

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
    - label: only if allergens are watched and a product's ingredient list is readable in this \
    frame: product name, whether ingredients are visible, which of the watched allergens the \
    ingredient text contains (in any language or as a derived ingredient, e.g. whey or casein \
    is milk), and the words you read as evidence. Otherwise null.
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
      "label":{"anyOf":[{"type":"null"},{"type":"object","properties":{
        "product":{"type":["string","null"]},
        "ingredients_visible":{"type":"boolean"},
        "allergens_found":{"type":"array","maxItems":12,"items":{"type":"string"}},
        "evidence":{"type":"string"}},
        "required":["product","ingredients_visible","allergens_found","evidence"]}]}},
     "required":["room","hands_visible","objects","actions","label"]}
    """#

    static func observeUser(watched: [String], allergens: [String], ocr: String) -> String {
        """
        Watched objects: \(watched.isEmpty ? "(none)" : watched.joined(separator: ", "))
        Watched allergens: \(allergens.isEmpty ? "(none)" : allergens.joined(separator: ", "))
        Text read on the phone (OCR, may be partial):
        \(ocr.isEmpty ? "(none)" : String(ocr.prefix(1500)))
        """
    }

    // MARK: Rules inside the answer call

    /// The part of the answer system prompt about safety rules (appended to `answerSystem`).
    static let answerRules = """

    SAFETY RULES (Muisti Turva). The user can ask Muisti to warn them about things it sees: \
    a stove left on when they leave home, a medicine not taken or taken twice, keys left at \
    home, an allergen on a product label, or "when you see X remind me Y". You get the current \
    rules, the watched objects' last known states and the recent safety log in the message.
    Extra actions, chosen in STEP 1 before "answer":
    - "create_rule": the user asks to be warned, reminded or watched over in the future. Fill \
    "rule" (below). "answer" is only the rule read back in one sentence in the user's language \
    followed by a short question whether it is right; do not comment on what was or was not \
    seen so far (nothing needs to have been seen to create a rule). Never create a rule from a \
    question about the past.
    - "confirm" / "cancel": the user answers yes / no to the pending item shown in the message \
    (a new rule, deleting a rule, or "did you take your medicine?"). Only when something is \
    pending. "answer" says in a few words that it is done (or dropped); never ask again.
    - "delete_rule": the user wants a rule removed or stopped. rule_id = the id of that rule; \
    "answer" asks them to confirm.
    - "log_event": the user tells you something they did or a state they set ("I took my \
    medicine", "I turned the stove off", "I locked the door"). Fill "event": object (a watched \
    object name, or a short English noun), kind ("action" or "state"), value (an action: took, \
    turned_on, turned_off, locked, unlocked, picked_up, put_down; or a state: on, off, open, \
    closed, locked, unlocked). "answer" acknowledges and says it was noted as their own words.
    - "leaving": the user says they are leaving or going out now (even if no home location is \
    set: Muisti then checks the rules itself). "arriving": they are home now. \
    "set_home": this place is their home. "answer" is a short acknowledgement; Muisti adds any \
    warning itself.
    - "snooze": "not now", "later", "stop warning me for a while", "I know" right after a warning (see "Last warning" and the previous exchange).
    - Questions about the rules or about states ("did I turn off the stove?", "did I take my \
    medicine today?", "what rules do I have?") are "answer": use the safety status and log. Say \
    what was SEEN and when ("I last saw the stove on at 18:42 and did not see you turn it \
    off"); never "the stove is on" or "you are safe". If the log entry came from the user's own \
    words, say so ("you told me at 19:05 that you turned it off; I did not see it"). Times you \
    state must be copied from the log.

    "rule" (only for create_rule, else null):
    - watch: canonical English names of the objects to watch: "stove", "keys", "wallet", \
    "door_lock", "medication:<name the user gives or the box shows>", "allergen:<allergen>". \
    Use exactly the same name in watch, trigger.object, condition.object and in a later \
    log_event (e.g. "medication:enalapril" everywhere). Names and allergens are English and \
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

    static let eventSchema = #"""
    {"anyOf":[{"type":"null"},{"type":"object","properties":{
      "object":{"type":"string"},
      "kind":{"type":"string","enum":["action","state"]},
      "value":{"type":"string"}},
     "required":["object","kind","value"]}]}
    """#
}
