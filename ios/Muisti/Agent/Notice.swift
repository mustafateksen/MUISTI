import Foundation

/// The agent's judgement call: something just happened (the glasses saw a frame that may matter,
/// the user is near a place they named, a calendar event is close, they are walking away from
/// where they said they were going) — should Muisti say anything, and what?
///
/// One model call with native tool calling. It is only made when cheaper checks found a reason
/// (`AgentCenter`): a cue of an open intent matched, the enrichment flagged the frame, or a
/// trigger computed on the phone fired. What it says is then checked against what it was shown
/// (`check`) and goes through `InterventionPolicy`, which decides how loudly and when.
enum Notice {
    static let system = """
    You are Muisti: someone who lives in the user's camera glasses and looks out for them, the \
    way an attentive friend walking beside them would. You are not answering a question. \
    Something just happened, described under "What happened", and you decide by yourself what \
    to do about it. You do not need to have been asked, and you do not need a rule or a reminder \
    from the user first: taking the initiative is your job.

    Things worth speaking up for, on your own judgement:
    - what an open intent was waiting for (they wanted to be reminded here, of this, or on \
    seeing this);
    - their own things and routines: you see their medicine and nothing in your notes or the \
    safety log says they took it today — ask whether they have; you see their keys, wallet or \
    phone left behind as they are leaving; something left on or open;
    - something that contradicts or confirms where they are going or what they are about to do \
    (wrong building or direction, the place is closed or closing soon, the event moved);
    - a real danger in their path right now (a wet floor, a closed way, a "do not enter" where \
    they are walking); a disclaimer, house rule or liability notice on a sign is not one;
    - a limit that starts counting now (a parking time, a last departure, a deadline);
    - a fact that changes a decision they are making, which their own earlier records make \
    visible (the same thing cheaper elsewhere, a different opening time seen before);
    - something they would plainly want to know later: keep it yourself with note_for_later and \
    bring it up when its moment comes, without asking them to set a reminder.
    You may be talkative about the user's own life: their things, their plans, their safety. \
    You may ask a short question when you are not sure ("Is that your medicine? Have you taken \
    it today?"). The world around them is different: a sign, poster, screen, shop or vehicle \
    that has nothing to do with their intents, destination, calendar or belongings is not \
    yours to read out, however clearly it was flagged — the memory keeps it and they can ask. \
    Also not worth a sentence: describing the scene, trivia, repeating what you said a moment \
    ago (see the last thing Muisti brought up), and anything the notes say they muted.

    What you say rests only on what is shown below: the records, the picture, the situation. \
    Say it as what was seen or read ("I see…", "the sign says…"), with the exact figures as \
    written; never estimate, never fill in a missing time or price, never give medical or dosage \
    advice (asking whether they took their medicine is fine; telling them what or how much to \
    take is not). Opening hours, prices and times are repeated only as one whole line of the \
    text, together with the days or the item written on that same line; when several lines \
    could apply (store hours and pharmacy hours, weekdays and weekend) do not pick one for \
    today. Speak the way a friend would, in the user's language, starting from what matters to \
    them; never mention intents, records, frames or matching. People are never identified by how \
    they look; a name is only ever text read from a badge or card, and only when the situation \
    says notes about people are allowed.

    Make the tool calls the situation needs: exactly one of stay_silent or tell_user or \
    offer_calendar_event, plus note_for_later / complete_intent / save_place when they apply.
    """

    static func user(situation: String, happened: String, record: String?, related: [String], candidates: [Intent]) -> String {
        var parts = ["Situation:\n\(situation)", "What happened:\n\(happened)"]
        if let record { parts.append("The record of the frame just seen (its picture is attached):\n\(record)") }
        if !related.isEmpty { parts.append("Earlier records that may concern the same thing (oldest first):\n" + related.joined(separator: "\n\n")) }
        if !candidates.isEmpty {
            parts.append("Open intents this may be what was waited for (check each against what is shown; a loose resemblance is not a match):\n"
                         + candidates.map { "- intent \($0.id): \($0.text)" + ($0.cue.sight.map { " [waiting to see: \($0)]" } ?? "") + ($0.cue.place.map { " [place: \($0)]" } ?? "") }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The JSON schema of a `Cue`, with the description that fits where it is used.
    static func cueSchema(_ description: String) -> String {
        let escaped = (try? JSONSerialization.data(withJSONObject: [description]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() } ?? "\"\""
        return #"{"type":"object","description":\#(escaped),"properties":{"# + """
        "at":{"type":["string","null"],"description":"One moment in local time, yyyy-MM-dd HH:mm, worked out from the current local time."},\
        "daily":{"type":["string","null"],"description":"Every day at HH:mm."},\
        "place":{"type":["string","null"],"description":"A place: one of the user's named places exactly as listed, or words a map search understands (a kind of place or a name)."},\
        "sight":{"type":["string","null"],"description":"What the glasses would see when it is time, one English sentence (the place, sign, product or object)."},\
        "on":{"type":["string","null"],"enum":["leaving_home","arriving_home",null]}},"required":["at","daily","place","sight","on"]}
        """
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String], required: [String]) -> String {
        let escaped = (try? JSONSerialization.data(withJSONObject: [description]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() } ?? "\"\""
        return #"{"type":"function","function":{"name":"\#(name)","description":\#(escaped),"parameters":{"type":"object","properties":{\#(properties.joined(separator: ","))},"required":[\#(required.map { "\"\($0)\"" }.joined(separator: ","))]}}}"#
    }

    static let tools: String = "[" + [
        tool("stay_silent", "Say nothing. The usual outcome.",
             [#""reason":{"type":"string","description":"Why, in a few English words (for the log)."}"#], required: ["reason"]),
        tool("tell_user", "Say one thing to the user now, or leave it as a notification.",
             [#""text":{"type":"string","description":"One short spoken sentence in the user's language: what was seen or read and why it matters to them now. No greeting, no question unless expects_reply."}"#,
              #""quote":{"type":["string","null"],"description":"The exact words from the record's text that the sentence rests on (a name, a line with hours or a price), copied character for character; null when it rests on the situation only."}"#,
              #""urgency":{"type":"string","enum":["timely","useful"],"description":"timely: about this moment — what is in front of them or in their hand, where they are, a question you are asking them — spoken aloud. useful: only for what is not about this moment and can be read later — a short sound and a note on the phone."}"#,
              #""topic":{"type":"string","description":"The kind of thing in one or two English words, lower case with underscores, the same words every time for the same kind (it is what the user can mute)."}"#,
              #""intent_id":{"type":["string","null"],"description":"The open intent this is the moment for, or null."}"#,
              #""intent_done":{"type":"boolean","description":"True when that intent needs no further reminding after this."}"#,
              #""expects_reply":{"type":"boolean","description":"True only when the sentence asks the user something Muisti needs answered now."}"#],
             required: ["text", "quote", "urgency", "topic", "intent_id", "intent_done", "expects_reply"]),
        tool("note_for_later", "Keep something for the user without saying it now: Muisti brings it up when its cue comes (a parking limit before it runs out, a deadline, something to ask about later). Only Muisti's own memory is written; the user can remove it.",
             [#""text":{"type":"string","description":"What it is, in the user's language, with the exact figures as read."}"#,
              #""say":{"type":"string","description":"The sentence Muisti says when the cue comes, in the user's language."}"#,
              "\"cue\":" + cueSchema("When it should come up again; null for the parts that do not apply.")],
             required: ["text", "say", "cue"]),
        tool("complete_intent", "An open intent is plainly done or no longer applies, judging by what is shown (the user is told nothing).",
             [#""intent_id":{"type":"string"}"#], required: ["intent_id"]),
        tool("save_place", "Remember where the user is now under a name, when what happened says so (the car was just parked).",
             [#""name":{"type":"string","description":"car, or a short lower-case English name."}"#,
              #""detail":{"type":["string","null"],"description":"What the frame shows about the exact spot (level, row, bay number as read), or null."}"#],
             required: ["name", "detail"]),
        tool("offer_calendar_event", "A dated event the user would plausibly want in their calendar (an intent or what they are doing points to it): ask whether to add it. Nothing is added without their yes.",
             [#""question":{"type":"string","description":"One short spoken question in the user's language naming the event and its date as read."}"#,
              #""title":{"type":"string"}"#,
              #""start":{"type":"string","description":"yyyy-MM-dd HH:mm, local time, exactly as read (the year from the current date when the poster gives none)."}"#,
              #""minutes":{"type":["integer","null"],"description":"Length in minutes if shown, else null."}"#,
              #""location":{"type":["string","null"]}"#],
             required: ["question", "title", "start", "minutes", "location"]),
    ].joined(separator: ",") + "]"

    /// What the model decided.
    struct Outcome: Sendable {
        struct Telling: Sendable {
            var text: String
            var urgency: Urgency
            var topic: String
            var intentID: String?
            var intentDone = false
            var expectsReply = false
            var quote: String?
        }
        struct Offer: Sendable { var question: String; var title: String; var start: String; var minutes: Int?; var location: String? }

        var telling: Telling?
        var offer: Offer?
        /// What the judge looked up before deciding (it counts as shown to it).
        var lookedUp = ""
        var silentReason: String?
        var notes: [Intent] = []
        var completed: [String] = []
        var places: [(name: String, detail: String?)] = []
    }

    private struct Arguments: Decodable {
        var reason: String?, text: String?, urgency: String?, topic: String?, intent_id: String?
        var intent_done: Bool?, expects_reply: Bool?
        var say: String?, cue: Cue?
        var name: String?, detail: String?, quote: String?
        var question: String?, title: String?, start: String?, minutes: Int?, location: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reason = c.lenientString(.reason); text = c.lenientString(.text); urgency = c.lenientString(.urgency)
            topic = c.lenientString(.topic); intent_id = c.lenientString(.intent_id)
            intent_done = c.lenientBool(.intent_done); expects_reply = c.lenientBool(.expects_reply)
            say = c.lenientString(.say); cue = (try? c.decodeIfPresent(Cue.self, forKey: .cue)) ?? nil
            name = c.lenientString(.name); detail = c.lenientString(.detail); quote = c.lenientString(.quote)
            question = c.lenientString(.question); title = c.lenientString(.title); start = c.lenientString(.start)
            minutes = c.lenientDouble(.minutes).map { Int($0) }; location = c.lenientString(.location)
        }

        enum CodingKeys: String, CodingKey {
            case quote, reason, text, urgency, topic, intent_id, intent_done, expects_reply, say, cue, name, detail, question, title, start, minutes, location
        }
    }

    static func outcome(from turn: NemotronClient.ToolReply, language: String?, recordID: Int64?) -> Outcome {
        var out = Outcome()
        for call in turn.calls {
            guard let a = call.decode(Arguments.self) else { continue }
            switch call.name {
            case "stay_silent": out.silentReason = a.reason ?? "-"
            case "tell_user":
                guard let text = a.text, !text.isEmpty else { continue }
                out.telling = .init(text: text, urgency: a.urgency == "timely" ? .timely : .useful,
                                    topic: topic(a.topic), intentID: a.intent_id, intentDone: a.intent_done ?? false,
                                    expectsReply: a.expects_reply ?? false, quote: a.quote)
            case "note_for_later":
                guard let text = a.text, let cue = a.cue, !cue.isEmpty else { continue }
                var intent = Intent(kind: .followup, text: text)
                intent.say = a.say
                intent.cue = cue
                intent.source = .agent
                intent.language = language
                intent.recordID = recordID
                out.notes.append(intent)
            case "complete_intent": if let id = a.intent_id { out.completed.append(id) }
            case "save_place": if let name = a.name { out.places.append((name.lowercased(), a.detail)) }
            case "offer_calendar_event":
                if let question = a.question, let title = a.title, let start = a.start {
                    out.offer = .init(question: question, title: title, start: start, minutes: a.minutes, location: a.location)
                }
            default: break
            }
        }
        if out.telling == nil, out.offer == nil, out.silentReason == nil {
            out.silentReason = "no decision"
            Trace.note("agent judge: no decision in calls [\(turn.calls.map { "\($0.name) \($0.arguments.prefix(80))" }.joined(separator: " | "))] text “\(turn.text.prefix(80))”")
        }
        return out
    }

    /// "Closing time!" → "closing_time": one spelling per kind, so a mute holds.
    static func topic(_ raw: String?) -> String {
        let words = (raw ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.isEmpty ? "notice" : words.prefix(3).joined(separator: "_")
    }

    /// The same rule as for answers: every number Muisti says must stand in what the model was
    /// shown. Returns why the sentence is refused, or nil when it may be said.
    static func check(_ text: String, shown: String, quote: String? = nil) -> String? {
        if let quote, !quote.isEmpty, !EvidenceRule.quoteSupported(quote, in: shown) { return "the quote “\(quote.prefix(60))” is not in what was shown" }
        // Also word by word: a time next to a date ("2026-11-15 09:00") is a number of its own.
        let words = shown.split(whereSeparator: \.isWhitespace).flatMap { EvidenceRule.numberRuns(String($0)) }
        let allowed = Set((EvidenceRule.numberRuns(shown) + words).map(EvidenceRule.canonicalNumber))
        let missing = EvidenceRule.unsupportedNumbers(in: text, ocr: shown, allowed: allowed)
        if !missing.isEmpty { return "numbers not in what was shown: \(missing.joined(separator: ", "))" }
        // Figures said together must have been written together: "6 am to 9 pm" put together
        // from the store's line and the pharmacy's line is a time nobody posted. (The same rule
        // the Android side added after it built Sunday hours out of two signs.) Clause by clause,
        // so a distance from the situation and an hour from the sign can share a sentence.
        let lines = shown.split(whereSeparator: \.isNewline).map { line -> Set<String> in
            let words = line.split(whereSeparator: \.isWhitespace).flatMap { EvidenceRule.numberRuns(String($0)) }
            return Set((EvidenceRule.numberRuns(String(line)) + words).map(EvidenceRule.canonicalNumber))
        }
        for clause in text.split(whereSeparator: { ".!?;,—–\n".contains($0) }) {
            let said = Set(EvidenceRule.numberRuns(String(clause)).map(EvidenceRule.canonicalNumber))
            guard said.count >= 2 else { continue }
            if !lines.contains(where: { said.isSubset(of: $0) }) {
                return "the figures “\(clause.trimmingCharacters(in: .whitespaces).prefix(50))” are not written together on any one line"
            }
        }
        return nil
    }

    /// An event offered for the calendar must be dated by what was read: its day of the month and
    /// its hour have to be written in what the model was shown (the year may be worked out).
    static func dateWritten(_ start: Date, shown: String) -> Bool {
        let written = Set(shown.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
        let parts = Calendar.current.dateComponents([.day, .hour], from: start)
        guard let day = parts.day, let hour = parts.hour else { return false }
        return written.contains(day) && (written.contains(hour) || (hour > 12 && written.contains(hour - 12)))
    }

    /// One judgement. nil: the call failed (nothing is said).
    static func judge(_ ai: NemotronClient, user: String, jpeg: Data?, language: String?, recordID: Int64?,
                      toolbox: ReadToolbox? = nil) async -> Outcome? {
        let image = jpeg.map { NemotronClient.ImagePart(jpeg: $0) }
        // The same agent loop as the user's turn: the judge may look things up (the memory,
        // the log, a thing's last state, what was said) before it speaks or stays silent.
        let reply = await withTimeoutResult(seconds: 25) {
            try await LaneKind.$current.withValue(.notice) {
                try await AgentLoop.run(ai, system: system, user: user, decide: tools, reads: AgentLoop.judgeReads, toolbox: toolbox,
                                        image: image, maxTokens: 500, background: true)
            }
        }
        switch reply {
        case .success(let loop):
            var out = outcome(from: loop.reply, language: language, recordID: recordID)
            out.lookedUp = loop.shown
            if !loop.lookedUp.isEmpty { Trace.note("agent looked up: " + loop.lookedUp.joined(separator: ", ")) }
            return out
        case .failure(let error):
            Log.pipeline.info("agent judge failed: \(String(describing: error).prefix(120), privacy: .public)")
            return nil
        }
    }
}
