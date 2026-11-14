import Foundation

/// Muisti Turva: the user's own safety rules, evaluated by code on events Muisti saw.
///
/// The model is used in exactly two places: turning a spoken sentence into a `SafetyRule`, and
/// reading the state of watched objects off a frame (`SafetyObservation`). Whether a rule fires
/// is decided here, deterministically, so an alert always says what was seen and when.
///
/// Object names are the model's canonical English nouns, shared by rules and observations:
/// "stove", "keys", "door_lock", "medication:<name on the box>", "allergen:<name>".

enum SafetySource: String, Codable, Sendable {
    case vision, user_voice, user_confirmed, system
}

enum SafetyEventKind: String, Codable, Sendable {
    case state, action, object_seen, label, context
}

/// Everything the safety layer saw or was told, newest last.
struct SafetyEvent: Sendable, Identifiable, Equatable {
    var id: Int64 = 0
    var at: Date
    var kind: SafetyEventKind
    var object: String?
    var value: String?
    var confidence: Double?
    var source: SafetySource
    /// Blurred evidence frame (file name in the safety frames folder).
    var frameFile: String?
    var latitude: Double?
    var longitude: Double?
    var zone: String?
    /// Free text: where the object was ("on the kitchen table"), what the label said.
    var detail: String?
}

/// Confirmed state of one watched object (state machine in `SafetyMonitor`).
struct ObjectState: Sendable, Equatable {
    var object: String
    var state: String               // on / off / open / closed / locked / unlocked / unknown …
    var since: Date
    /// Last time the object was visible at all.
    var lastSeen: Date
    /// Last time it was seen in the current state (the time an alert names).
    var lastStateSeen: Date
    var evidenceFrame: String?
    var pendingOnCount: Int = 0
    var source: SafetySource = .vision
    var place: String?
    /// In a state that is risky if left that way (on, burning, running, open).
    var active: Bool = false
    /// Flagged by the frame model on its own (not from a user rule).
    var hazard: Bool = false
}

struct SafetyRule: Codable, Sendable, Identifiable, Equatable {
    enum TriggerType: String, Codable, Sendable { case context, schedule, event, inactivity }
    enum Severity: String, Codable, Sendable { case high, medium, low }

    struct Trigger: Codable, Sendable, Equatable {
        var type: TriggerType
        /// context: "left_home" | "arrived_home".
        var event: String?
        /// schedule: local time "HH:mm"; the rule is checked at time + grace_min, daily.
        var time: String?
        var grace_min: Int?
        /// event: fires when this object is observed (e.g. a medication "in_hand"), or "label"
        /// for a product label (allergen rules), or any object class for a free rule.
        var object: String?
        var state: String?
        /// inactivity: minutes the object stayed in `state` without being looked at.
        var minutes: Int?
    }

    struct Condition: Codable, Sendable, Equatable {
        var object: String?
        /// The object's confirmed state must be this …
        var last_state: String?
        /// … and must not have changed to this since.
        var not_followed_by: String?
        /// An action ("took", "locked", …) on `object` within the window …
        var action: String?
        /// … at least this many times (e.g. 1 = "already taken today"); nil = it must NOT have
        /// happened (e.g. "medicine not taken by 08:30").
        var count_at_least: Int?
        /// Window in minutes back from now; nil = since 00:00 today.
        var within_min: Int?
        /// The object was seen in the last N minutes (keys left at home).
        var seen_within_min: Int?
        /// Allergens to look for on a product label.
        var allergens: [String]?
    }

    var id: String
    /// The rule read back to the user, in their language ("When you leave home …").
    var summary: String
    var language: String?
    var watch: [String]
    var trigger: Trigger
    var condition: Condition
    var severity: Severity
    /// Spoken alert. Placeholders: {last_seen_time}, {place}, {action_time}, {allergens},
    /// {product}. Says what was seen, never a conclusion ("I last saw the stove on at 18:42").
    var message: String
    var cooldown_min: Int
    var enabled: Bool
    /// Yes/no question to confirm the action when it is seen ("Did you take your Enalapril?").
    var confirm_question: String?

    var confirmQuestion: String? { confirm_question.flatMap { $0.isEmpty ? nil : $0 } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 } ?? UUID().uuidString
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        watch = ((try? c.decodeIfPresent([String].self, forKey: .watch)) ?? nil)?.map { $0.lowercased() } ?? []
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        condition = (try? c.decodeIfPresent(Condition.self, forKey: .condition)) ?? Condition()
        severity = ((try? c.decodeIfPresent(Severity.self, forKey: .severity)) ?? nil) ?? .medium
        message = try c.decode(String.self, forKey: .message)
        cooldown_min = ((try? c.decodeIfPresent(Int.self, forKey: .cooldown_min)) ?? nil) ?? 30
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        confirm_question = (try? c.decodeIfPresent(String.self, forKey: .confirm_question)) ?? nil
        // Lower-case object names everywhere: the model is asked for them, but matching must not
        // depend on capitalisation.
        trigger.object = trigger.object?.lowercased()
        condition.object = condition.object?.lowercased()
        condition.allergens = condition.allergens?.map { $0.lowercased() }
        // One name per object: "enalapril" in the trigger and "medication:enalapril" in watch
        // are the same thing; use the watch list's full name everywhere.
        let names = watch
        func canonical(_ name: String?) -> String? {
            guard let name, name != "label" else { return name }
            return names.first { $0 == name || $0.hasSuffix(":" + name) } ?? name
        }
        trigger.object = canonical(trigger.object)
        condition.object = canonical(condition.object)
    }

    init(id: String = UUID().uuidString, summary: String, language: String? = nil, watch: [String], trigger: Trigger,
         condition: Condition, severity: Severity, message: String, cooldown_min: Int = 30, enabled: Bool = true,
         confirm_question: String? = nil) {
        self.confirm_question = confirm_question
        self.id = id
        self.summary = summary
        self.language = language
        self.watch = watch
        self.trigger = trigger
        self.condition = condition
        self.severity = severity
        self.message = message
        self.cooldown_min = cooldown_min
        self.enabled = enabled
    }

    /// Objects the frame model is asked about for this rule.
    var watchedObjects: [String] {
        var all = watch
        for o in [trigger.object, condition.object].compactMap({ $0 }) where o != "label" && !all.contains(o) { all.append(o) }
        return all
    }
}

struct SafetyAlert: Sendable, Identifiable, Equatable {
    enum Response: String, Sendable { case dismissed, snoozed, confirmed }
    var id: Int64 = 0
    var at: Date
    var ruleID: String
    var message: String
    var evidenceFrame: String?
    var severity: SafetyRule.Severity
    var response: Response?
}

/// One frame read by the safety model, for the watched objects only.
struct SafetyObservation: Codable, Sendable, Equatable {
    struct Object: Codable, Sendable, Equatable {
        var name: String
        var visible: Bool
        var state: String
        var location_hint: String?
        var evidence: String
    }
    struct Action: Codable, Sendable, Equatable {
        var object: String
        var action: String
    }
    /// A household hazard the model noticed by itself (no rule needed).
    struct Hazard: Codable, Sendable, Equatable {
        var object: String
        var state: String
        /// Risky if it stays like this (left on, burning, running, open).
        var active: Bool
        /// Dangerous right now (smoke, fire outside a hob, boiling over, sparks).
        var immediate: Bool
        var location_hint: String?
        var evidence: String
    }
    struct Label: Codable, Sendable, Equatable {
        var product: String?
        var ingredients_visible: Bool
        /// "ingredients" (read from the list) or "front" (name, flavour or picture on the front).
        var source: String?
        var allergens_found: [String]
        var evidence: String
    }

    var room: String
    var hands_visible: Bool?
    var objects: [Object]
    var actions: [Action]
    var label: Label?
    var hazards: [Hazard]

    init(room: String, hands_visible: Bool? = nil, objects: [Object] = [], actions: [Action] = [], label: Label? = nil,
         hazards: [Hazard] = []) {
        self.room = room
        self.hands_visible = hands_visible
        self.objects = objects
        self.actions = actions
        self.label = label
        self.hazards = hazards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = ((try? c.decodeIfPresent(String.self, forKey: .room)) ?? nil)?.lowercased() ?? "unknown"
        hands_visible = try? c.decodeIfPresent(Bool.self, forKey: .hands_visible)
        objects = ((try? c.decodeIfPresent([Object].self, forKey: .objects)) ?? nil) ?? []
        actions = (((try? c.decodeIfPresent([Action].self, forKey: .actions)) ?? nil) ?? [])
            .filter { $0.action != "none" }
        label = (try? c.decodeIfPresent(Label.self, forKey: .label)) ?? nil
        hazards = (((try? c.decodeIfPresent([Hazard].self, forKey: .hazards)) ?? nil) ?? []).map {
            var h = $0
            h.object = h.object.lowercased()
            h.state = h.state.lowercased()
            return h
        }
        objects = objects.map { var o = $0; o.name = o.name.lowercased(); o.state = o.state.lowercased(); return o }
        actions = actions.map { Action(object: $0.object.lowercased(), action: $0.action.lowercased()) }
        if var l = label {
            l.allergens_found = l.allergens_found.map { $0.lowercased() }
            label = l
        }
    }
}

/// Something Muisti is waiting for the user to confirm with a yes / no.
enum SafetyPending: Sendable, Equatable {
    case rule(SafetyRule)
    case deleteRule(SafetyRule)
    /// "Did you take your Enalapril?" after the box was seen in hand.
    case action(object: String, action: String, frame: String?, seenAt: Date)

    var prompt: String {
        switch self {
        case .rule(let rule): return "New rule waiting for a yes/no: \(rule.summary)"
        case .deleteRule(let rule): return "Deleting this rule, waiting for a yes/no: \(rule.summary)"
        case .action(let object, let action, _, let at):
            return "Asked the user to confirm the action \"\(action)\" on \(object) seen at \(QueryEngine.promptTime(at)); waiting for a yes/no."
        }
    }
}
