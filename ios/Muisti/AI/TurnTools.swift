import Foundation

/// The first call of every turn, with native tool calling: the model either replies directly
/// (greetings, thanks, small talk, general knowledge) or calls a tool — look through the
/// glasses, search the memory, forget, or a Muisti Turva command.
///
/// This replaced the router call and the "which action is this" part of the answer prompt
/// (a required `action` enum, a `question_is_about_what_user_sees_now` flag and pages of text on
/// when to pick which). What each tool is for now sits in its own description, and answering
/// from memory (`MemoryPrompts.answerSystem`) only has to answer.
enum TurnTools {
    static let system = """
    You are Muisti, an assistant that lives in the user's camera glasses. The glasses photograph \
    what the user looks at while they go about their day, and the phone keeps it as their \
    memory; you can also look through the glasses right now, you keep safety rules for the user \
    (Muisti Turva), and you keep what they ask you to remind them of, where they are going and \
    what they tell you about themselves, bringing it up by yourself when its moment comes. The user talks to you, usually by voice, so a message may contain \
    speech-recognition errors: read it for what was most likely meant, using the conversation.

    Every turn is exactly one tool call; the tool descriptions say which. By yourself you know \
    nothing about what the user saw, sees, did or told you earlier, nor about their rules: only \
    search_memory and look_now do, so a reply that claims or denies something about the user's \
    day, surroundings or memory without them would be made up. A short message often answers \
    what you just asked or warned about, so read the conversation and the pending yes/no first.
    """

    static func user(question: String, now: Date, conversation: [String], safety: String, lookedSecondsAgo: Int?, position: String? = nil) -> String {
        """
        Current local time: \(QueryEngine.promptTime(now))
        User position now: \(position ?? "unknown")
        Conversation so far (oldest first):
        \(conversation.isEmpty ? "(new conversation)" : conversation.joined(separator: "\n"))
        \(lookedSecondsAgo.map { "Your last reply looked through the glasses \($0) seconds ago.\n" } ?? "")
        What Muisti keeps (Muisti Turva: safety rules, watched objects, safety log, pending yes/no; then its own notes: intents, destination, places, what the user told it):
        \(safety.isEmpty ? "(nothing yet)" : safety)

        Message: \(question)
        """
    }

    private static let searchPlace = #""place":{"type":["string","null"],"description":"Always decide this. When the user's message names a place on the map that the thing should have been seen in — a city, district, street, building or venue (\"in Istanbul\", \"at the airport\", \"Stockholm'da\"), or a place Muisti keeps (\"home\", \"work\") — give that name here and leave it out of query. When they say here, this place, this building, around here (\"burada\", \"täällä\"), give the single word here: it means their position now, so never put a place name from the conversation in its stead. Only records made there are searched. Null when the message names no place, and null when it asks where something is (\"where was the pharmacy\")."}"#

    /// The second round of a question whose first search found nothing that answers it.
    static let againSystem = """
    You are Muisti's memory search. The user asked something about what their glasses saw; the \
    first search of the memory found nothing that answers it. Decide in one tool call: \
    search_memory once more when other words could find it (the word a sign or shop front would \
    carry, a synonym, a broader or narrower kind of thing, the local language of the signs, a \
    wider span of time), or give_up when the first search already looked for the right thing \
    and it simply was not seen. Never repeat the first query, and never drop or change a place \
    or a span of time the user named.
    """

    static func againUser(question: String, now: Date, position: String?, conversation: [String], first: String, found: [String]) -> String {
        """
        Current local time: \(QueryEngine.promptTime(now))
        User position now: \(position ?? "unknown")
        Conversation so far (oldest first):
        \(conversation.isEmpty ? "(new conversation)" : conversation.joined(separator: "\n"))

        Question: \(question)
        First search: \(first)
        What it found instead (best first):
        \(found.isEmpty ? "(nothing)" : found.joined(separator: "\n"))
        """
    }

    static let againTools: String = "[" + [
        tool("search_memory", "Search the memory once more with other words.",
             properties: [#""query":{"type":"string","description":"What to look for this time, complete by itself, in different words from the first search."}"#,
                          #""from":{"type":["string","null"],"description":"Start of the span of time the user named, yyyy-MM-dd HH:mm local time; else null."}"#,
                          #""to":{"type":["string","null"],"description":"End of that span; else null."}"#,
                          searchPlace],
             required: ["query", "place"]),
        tool("give_up", "The first search looked for the right thing: it was not seen."),
    ].joined(separator: ",") + "]"

    private static let reply = #"{"type":"string","description":"What Muisti says to the user: one short spoken sentence in the language of the user's message (a Turkish message gets a Turkish reply, whatever the conversation was in before)."}"#

    private static func tool(_ name: String, _ description: String, properties: [String] = [], required: [String] = []) -> String {
        let escaped = (try? JSONSerialization.data(withJSONObject: [description]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() } ?? "\"\""
        let need = required.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"function","function":{"name":"\#(name)","description":\#(escaped),"parameters":{"type":"object","properties":{\#(properties.joined(separator: ","))},"required":[\#(need)]}}}"#
    }

    /// The OpenAI `tools` array (JSON text).
    static let tools: String = "[" + [
        tool("say", """
             Speak to the user directly, without looking anything up. Only for a greeting, thanks, a \
             reaction ("ok", "great"), small talk, a question about yourself, or general knowledge \
             ("what is an Arduino?") — never for anything about what the user saw or sees, where or \
             when something was, what a sign says, or their rules and medicines (also not to say you \
             do not have it: search_memory finds that out). Never to ask the user what "this", "that" or \
             "it" is, or to ask them to read out something they are plainly looking at ("can you solve \
             this", "what does this mean", "help me with this"): you have eyes, so look_now first.
             """,
             properties: [#""text":{"type":"string","description":"One or two short, natural spoken sentences in the user's language, no markdown. General knowledge is fine but is never presented as something the user saw. Ending with a question opens the user's microphone again: only when you need their answer now. Thanks, \"ok\" or \"bye\" get a short closing with no question and no offer."}"#],
             required: ["text"]),
        tool("look_now", """
             See what is in front of the user right now through the glasses camera. Call it whenever the \
             message is about the present view, in any words or language: what is this, what do you see, \
             look, read this, what does it say, what colour is it, is it on, is this the right one, \
             "this" or "here" pointing at something, a garbled request about seeing or looking, or a \
             "yes" to your own offer to look. You can always look: never say you cannot see.
             """),
        tool("search_memory", """
             Look up what the glasses saw earlier and what Muisti Turva knows: places, signs and their \
             text, objects, when and where something was, what came before or after it, the safety \
             rules, the watched objects' states, medicines, and what the user told you. Call it for \
             every question about the user's own day or surroundings in the past, also follow-ups \
             ("and the phone number?", "what was next to it?", "are you sure?", "what does it say \
             exactly?" about something already looked at): the answer is checked against the evidence \
             there, which the conversation alone cannot do.
             """,
             properties: [#""query":{"type":"string","description":"What to look for, complete by itself: replace \"it\", \"there\", \"that place\" with what the conversation was about."}"#,
                          #""from":{"type":["string","null"],"description":"Only when the user named a span of time (\"yesterday\", \"this morning\", \"between 2 and 3\"): its start in local time, yyyy-MM-dd HH:mm, worked out from the current local time. Otherwise null."}"#,
                          #""to":{"type":["string","null"],"description":"The end of that span, yyyy-MM-dd HH:mm; null when there is none or it runs until now."}"#,
                          searchPlace],
             required: ["query", "place"]),
        tool("forget_recent", """
             Delete recent memories. Only when the user explicitly asks to forget or delete what the \
             glasses saw ("forget the last 10 minutes", "delete what you saw today"); never for a \
             question that only mentions forgetting.
             """,
             properties: [#""minutes":{"type":"integer","description":"How many minutes back from now to delete: \"today\" = minutes since 00:00, \"this morning\" = minutes since 06:00; no span given = 10."}"#,
                          "\"reply\":" + reply],
             required: ["minutes", "reply"]),
        tool("create_rule", """
             A safety rule: the user asks to be warned or watched over about a household object's \
             state (stove, iron, door, keys, wallet), a medicine they take, or a food allergen ("warn \
             me if I leave the stove on", "remind me of my pill every morning", "tell me when \
             something contains nuts", in any language). Anything else they want to be reminded of is \
             remember_intent. Never from a question about the past. The reply reads the rule back in one sentence and asks \
             whether it is right; nothing needs to have been seen yet.

             """ + SafetyPrompts.ruleGuide,
             properties: ["\"rule\":" + SafetyPrompts.ruleObjectSchema, "\"reply\":" + reply],
             required: ["rule", "reply"]),
        tool("confirm_pending", """
             The user says yes (yes, right, okay, do it, evet, kyllä …) to the pending yes/no shown in \
             the message: a new rule, deleting a rule, or a question Muisti asked. Only when something \
             is pending. The reply says in a few words that it is done; never ask again.
             """, properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("cancel_pending", """
             The user says no to the pending yes/no shown in the message. Only when something is \
             pending. The reply says in a few words that it was dropped.
             """, properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("delete_rule", "The user wants a rule removed or stopped. The reply asks them to confirm.",
             properties: [#""rule_id":{"type":"string","description":"The id of that rule, from the safety rules in the message."}"#,
                          "\"reply\":" + reply],
             required: ["rule_id", "reply"]),
        tool("log_event", """
             The user tells you something they did or a state they set ("I took my medicine", "I \
             turned the stove off", "I locked the door"). Not for a yes/no to a pending question. The \
             reply acknowledges and says it was noted as their own words.
             """,
             properties: [#""object":{"type":"string","description":"A watched object's name exactly as in the rules (e.g. medication:enalapril), or a short English noun."}"#,
                          #""kind":{"type":"string","enum":["action","state"]}"#,
                          #""value":{"type":"string","description":"An action (took, turned_on, turned_off, locked, unlocked, picked_up, put_down) or a state (on, off, open, closed, locked, unlocked)."}"#,
                          "\"reply\":" + reply],
             required: ["object", "kind", "value", "reply"]),
        tool("leaving_home", "The user says they are leaving or going out now. The reply is a short acknowledgement; Muisti adds any warning itself.",
             properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("arrived_home", "The user says they are home now. The reply is a short acknowledgement.",
             properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("set_home", "The user says this place is their home. The reply is a short acknowledgement.",
             properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("snooze_warning", """
             "Not now", "later", "I know", "stop warning me for a while" right after a warning or after \
             something Muisti brought up by itself (see the last warning, the last thing Muisti brought \
             up and the conversation). The reply says Muisti will stay quiet about it for 30 minutes.
             """, properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("remember_intent", """
             The user wants to be reminded of something or says what they intend to do: an errand, \
             something to buy, a call to make, a thing to ask about ("remind me to…", "I need to buy \
             milk tomorrow", "tell me when we pass a pharmacy", "don't let me forget my umbrella when I \
             leave", in any language). Muisti keeps it and brings it up by itself when its cue comes. \
             Not for safety rules (create_rule), and not for something they only mention having done. \
             The reply confirms in one sentence what will be brought up and when.
             """,
             properties: [#""text":{"type":"string","description":"What it is, in the user's own words and language, complete by itself."}"#,
                          #""say":{"type":"string","description":"The one short sentence Muisti says when the moment comes, in the user's language (\"You wanted to buy milk.\")."}"#,
                          #""kind":{"type":"string","enum":["reminder","todo","watch"],"description":"todo: something to get or do with no fixed moment (shopping, errands). reminder: tied to a time or a place. watch: tell me whenever you see this, more than once."}"#,
                          "\"cue\":" + Notice.cueSchema("When to bring it up; null for the parts that do not apply. Fill every part that does: a time the user gave (worked out from the current local time); place, whenever the thing is done at a kind of place even if the user named none (something to buy: the kind of shop that sells it; a prescription: a pharmacy); and sight, what the glasses would see at that moment (the shop's sign or shelves as well as the thing itself)."),
                          "\"reply\":" + reply],
             required: ["text", "say", "kind", "cue", "reply"]),
        tool("set_destination", """
             The user says where they are going now ("I'm going to the pharmacy", "take me to hall 3", \
             "I need to find gate B12"). Muisti follows along and speaks up if they walk away from it \
             or reach it. The reply acknowledges in a few words.
             """,
             properties: [#""place":{"type":"string","description":"The place as a name or as words a map search understands, or one of the user's named places exactly as listed."}"#,
                          "\"reply\":" + reply],
             required: ["place", "reply"]),
        tool("cancel_destination", "The user is no longer going to the destination shown in the message, or has arrived and says so.",
             properties: ["\"reply\":" + reply], required: ["reply"]),
        tool("complete_intent", "The user says an open intent listed in the message is done (\"I bought the milk\", \"done\", \"got it\" right after Muisti brought it up).",
             properties: [#""intent_id":{"type":"string","description":"The id of that intent, from the open intents in the message."}"#,
                          "\"reply\":" + reply],
             required: ["intent_id", "reply"]),
        tool("drop_intent", "The user no longer wants an open intent listed in the message (\"forget the milk\", \"never mind that reminder\").",
             properties: [#""intent_id":{"type":"string","description":"The id of that intent, from the open intents in the message."}"#,
                          "\"reply\":" + reply],
             required: ["intent_id", "reply"]),
        tool("remember_fact", """
             The user tells Muisti something lasting about themselves or their things for it to keep \
             ("my car is a blue Toyota", "I'm vegetarian", "my hotel room is 412", "my sister's name \
             is Elif"). Not an errand (remember_intent), not something they did (log_event).
             """,
             properties: [#""text":{"type":"string","description":"The fact as one sentence in the user's language, in the third person about the user."}"#,
                          "\"reply\":" + reply],
             required: ["text", "reply"]),
        tool("name_place", "The user gives the place they are at right now a name (\"this is my office\", \"I parked here\", \"remember this spot as the meeting point\"). For their home use set_home.",
             properties: [#""name":{"type":"string","description":"A short lower-case name: work, car, or what the user called it."}"#,
                          "\"reply\":" + reply],
             required: ["name", "reply"]),
        tool("mute_topic", """
             The user does not want to be told this kind of thing again ("don't tell me that again", \
             "stop telling me about prices", "enough with that reminder"), usually right after \
             something Muisti brought up by itself (see the last thing Muisti brought up). Not for a \
             short pause (snooze_warning).
             """,
             properties: [#""topic":{"type":["string","null"],"description":"The topic to mute, exactly as shown in the last thing Muisti brought up or in the muted list; null when it is about one intent."}"#,
                          #""intent_id":{"type":["string","null"],"description":"The intent to stop reminding about, or null."}"#,
                          #""minutes":{"type":["integer","null"],"description":"For how long, when the user gave a span; null = for good."}"#,
                          "\"reply\":" + reply],
             required: ["topic", "intent_id", "minutes", "reply"]),
        tool("summarize_day", "The user asks for a summary of their day (\"how was my day\", \"what did I do today\", \"sum up today\"). Muisti writes it from the day's records.",
             properties: [], required: []),
        tool("add_to_calendar", """
             The user asks to put an event into their calendar, with a date and time they said or that \
             the conversation just established from something seen ("add that concert to my calendar"). \
             The reply says it was added, with the date.
             """,
             properties: [#""title":{"type":"string"}"#,
                          #""start":{"type":"string","description":"yyyy-MM-dd HH:mm, local time, worked out from the current local time."}"#,
                          #""minutes":{"type":["integer","null"],"description":"Length in minutes if known, else null."}"#,
                          #""location":{"type":["string","null"]}"#,
                          "\"reply\":" + reply],
             required: ["title", "start", "minutes", "location", "reply"]),
    ].joined(separator: ",") + "]"

    /// What the model decided for this turn.
    enum Decision: Sendable {
        case reply(String)
        case look
        /// `from`/`to`: the span of time the user named, if any; `place`: the place they named.
        case search(String?, from: Date? = nil, to: Date? = nil, place: String? = nil)
        case forget(minutes: Int?, reply: String)
        case command(SafetyCommand, reply: String, tool: String)
        /// Something for the agent side: an intent, a destination, a place, a mute.
        case agent(AgentCommand, reply: String, tool: String)
    }

    private struct Arguments: Decodable {
        var query: String?
        var text: String?
        var minutes: Int?
        var reply: String?
        var rule: SafetyRule?
        var rule_id: String?
        var object: String?
        var kind: String?
        var value: String?
        var say: String?
        var cue: Cue?
        var place: String?
        var intent_id: String?
        var name: String?
        var topic: String?
        var title: String?
        var start: String?
        var location: String?
        var from: String?
        var to: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            query = c.lenientString(.query)
            text = c.lenientString(.text)
            minutes = c.lenientDouble(.minutes).map { Int($0) }
            reply = c.lenientString(.reply)
            rule = (try? c.decodeIfPresent(SafetyRule.self, forKey: .rule)) ?? nil
            rule_id = c.lenientString(.rule_id)
            object = c.lenientString(.object)
            kind = c.lenientString(.kind)
            value = c.lenientString(.value)
            say = c.lenientString(.say)
            cue = (try? c.decodeIfPresent(Cue.self, forKey: .cue)) ?? nil
            place = c.lenientString(.place)
            intent_id = c.lenientString(.intent_id)
            name = c.lenientString(.name)
            topic = c.lenientString(.topic)
            title = c.lenientString(.title)
            start = c.lenientString(.start)
            location = c.lenientString(.location)
            from = c.lenientString(.from)
            to = c.lenientString(.to)
        }

        enum CodingKeys: String, CodingKey {
            case query, text, minutes, reply, rule, rule_id, object, kind, value
            case say, cue, place, intent_id, name, topic, title, start, location, from, to
        }
    }

    /// Reads the model's turn. Arguments are checked here (a model may send a call with missing
    /// or made-up arguments): a command without what it needs falls back to a memory search,
    /// which answers from evidence instead of acting on a guess.
    static func decision(from turn: NemotronClient.ToolReply) -> Decision {
        var looked = false
        var search: (query: String?, from: Date?, to: Date?, place: String?)?
        for call in turn.calls {
            let args = call.decode(Arguments.self)
            let reply = args?.reply ?? turn.text
            switch call.name {
            case "say":
                if let text = args?.text { return .reply(text) }
            case "look_now": looked = true
            case "search_memory":
                let now = Date()
                search = (args?.query, args?.from.flatMap { Cue(at: $0).nextDue(after: now) }, args?.to.flatMap { Cue(at: $0).nextDue(after: now) },
                          args?.place.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.lowercased() == "null" ? nil : $0 })
            case "forget_recent": return .forget(minutes: args?.minutes, reply: reply)
            case "create_rule":
                if let rule = args?.rule { return .command(.createRule(rule), reply: reply, tool: call.name) }
            case "confirm_pending": return .command(.confirm, reply: reply, tool: call.name)
            case "cancel_pending": return .command(.cancel, reply: reply, tool: call.name)
            case "delete_rule":
                if let id = args?.rule_id { return .command(.deleteRule(id), reply: reply, tool: call.name) }
            case "log_event":
                if let object = args?.object, let value = args?.value {
                    return .command(.logEvent(object: object.lowercased(), kind: args?.kind?.lowercased() == "state" ? .state : .action,
                                              value: value.lowercased()), reply: reply, tool: call.name)
                }
            case "leaving_home": return .command(.leaving, reply: reply, tool: call.name)
            case "arrived_home": return .command(.arriving, reply: reply, tool: call.name)
            case "set_home": return .command(.setHome, reply: reply, tool: call.name)
            case "snooze_warning": return .command(.snooze, reply: reply, tool: call.name)
            case "remember_intent":
                if let text = args?.text {
                    let kind = Intent.Kind(rawValue: args?.kind?.lowercased() ?? "") ?? .reminder
                    return .agent(.remember(text: text, say: args?.say, kind: kind, cue: args?.cue ?? Cue()), reply: reply, tool: call.name)
                }
            case "set_destination":
                if let place = args?.place { return .agent(.setDestination(place), reply: reply, tool: call.name) }
            case "cancel_destination": return .agent(.cancelDestination, reply: reply, tool: call.name)
            case "complete_intent":
                if let id = args?.intent_id { return .agent(.complete(id), reply: reply, tool: call.name) }
            case "drop_intent":
                if let id = args?.intent_id { return .agent(.drop(id), reply: reply, tool: call.name) }
            case "remember_fact":
                if let text = args?.text { return .agent(.rememberFact(text), reply: reply, tool: call.name) }
            case "name_place":
                if let name = args?.name { return .agent(.namePlace(name), reply: reply, tool: call.name) }
            case "mute_topic":
                return .agent(.mute(topic: args?.topic, intentID: args?.intent_id, minutes: args?.minutes), reply: reply, tool: call.name)
            case "summarize_day": return .agent(.summarizeDay, reply: reply, tool: call.name)
            case "add_to_calendar":
                if let title = args?.title, let start = args?.start {
                    return .agent(.addToCalendar(title: title, start: start, minutes: args?.minutes, location: args?.location), reply: reply, tool: call.name)
                }
            default: break
            }
        }
        if looked { return .look }
        if let search { return .search(search.query, from: search.from, to: search.to, place: search.place) }
        // A tool call that could not be used and no words: answer from memory.
        return turn.text.isEmpty ? .search(nil) : .reply(turn.text)
    }
}
