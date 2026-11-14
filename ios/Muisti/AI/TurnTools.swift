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
    memory; you can also look through the glasses right now, and you keep safety rules for the \
    user (Muisti Turva). The user talks to you, usually by voice, so a message may contain \
    speech-recognition errors: read it for what was most likely meant, using the conversation.

    Every turn is exactly one tool call; the tool descriptions say which. By yourself you know \
    nothing about what the user saw, sees, did or told you earlier, nor about their rules: only \
    search_memory and look_now do, so a reply that claims or denies something about the user's \
    day, surroundings or memory without them would be made up. A short message often answers \
    what you just asked or warned about, so read the conversation and the pending yes/no first.
    """

    static func user(question: String, now: Date, conversation: [String], safety: String, lookedSecondsAgo: Int?) -> String {
        """
        Current local time: \(QueryEngine.promptTime(now))
        Conversation so far (oldest first):
        \(conversation.isEmpty ? "(new conversation)" : conversation.joined(separator: "\n"))
        \(lookedSecondsAgo.map { "Your last reply looked through the glasses \($0) seconds ago.\n" } ?? "")
        Muisti Turva (safety rules, watched objects, safety log, pending yes/no):
        \(safety.isEmpty ? "(no safety rules)" : safety)

        Message: \(question)
        """
    }

    private static let reply = #"{"type":"string","description":"What Muisti says to the user: one short spoken sentence in the user's language."}"#

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
             do not have it: search_memory finds that out).
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
             properties: [#""query":{"type":"string","description":"What to look for, complete by itself: replace \"it\", \"there\", \"that place\" with what the conversation was about."}"#],
             required: ["query"]),
        tool("forget_recent", """
             Delete recent memories. Only when the user explicitly asks to forget or delete what the \
             glasses saw ("forget the last 10 minutes", "delete what you saw today"); never for a \
             question that only mentions forgetting.
             """,
             properties: [#""minutes":{"type":"integer","description":"How many minutes back from now to delete: \"today\" = minutes since 00:00, \"this morning\" = minutes since 06:00; no span given = 10."}"#,
                          "\"reply\":" + reply],
             required: ["minutes", "reply"]),
        tool("create_rule", """
             The user asks to be warned, reminded or watched over in the future ("warn me if…", \
             "remind me…", in any language), also when it mentions things bought or seen. Never from \
             a question about the past. The reply reads the rule back in one sentence and asks \
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
             "Not now", "later", "I know", "stop warning me for a while" right after a warning (see the \
             last warning and the conversation). The reply says Muisti will stay quiet about it for 30 minutes.
             """, properties: ["\"reply\":" + reply], required: ["reply"]),
    ].joined(separator: ",") + "]"

    /// What the model decided for this turn.
    enum Decision: Sendable {
        case reply(String)
        case look
        case search(String?)
        case forget(minutes: Int?, reply: String)
        case command(SafetyCommand, reply: String, tool: String)
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
        }

        enum CodingKeys: String, CodingKey { case query, text, minutes, reply, rule, rule_id, object, kind, value }
    }

    /// Reads the model's turn. Arguments are checked here (a model may send a call with missing
    /// or made-up arguments): a command without what it needs falls back to a memory search,
    /// which answers from evidence instead of acting on a guess.
    static func decision(from turn: NemotronClient.ToolReply) -> Decision {
        var looked = false
        var search: String??
        for call in turn.calls {
            let args = call.decode(Arguments.self)
            let reply = args?.reply ?? turn.text
            switch call.name {
            case "say":
                if let text = args?.text { return .reply(text) }
            case "look_now": looked = true
            case "search_memory": search = .some(args?.query)
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
            default: break
            }
        }
        if looked { return .look }
        if let search { return .search(search) }
        // A tool call that could not be used and no words: answer from memory.
        return turn.text.isEmpty ? .search(nil) : .reply(turn.text)
    }
}
