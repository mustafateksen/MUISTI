import Foundation

/// The conversation as every model call reads it (pipeline v2, §4.2): the same blocks in the
/// same order for the turn decision, the answer and the agent's own judgement, so none of them
/// works from a different picture of what was said. Stable parts first (summaries change a few
/// times a day), the latest turns last.
enum ContextBuilder {
    /// Turns read word for word.
    static let verbatimTurns = 12
    /// More open turns than this: the oldest are folded into a summary.
    static let summarizeAbove = 20
    static let summarizeBatch = 8

    /// Lines for the "Conversation so far" part of a prompt: what was summarised (yesterday
    /// and today), Muisti's own short notes, then the latest turns as they were said.
    static func conversation(_ dialog: DialogStore, now: Date = Date()) async -> [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var lines: [String] = []
        let summaries = await dialog.summaries(since: yesterday)
        if !summaries.isEmpty {
            lines.append("Earlier in the conversation (summarised; names and numbers as they were said):")
            lines += summaries.map { "- \($0.at < today ? "yesterday" : QueryEngine.clock($0.at)): \($0.text)" }
        }
        let notes = await dialog.notes(now: now)
        if !notes.isEmpty {
            lines.append("Your own notes (kept until they expire):")
            lines += notes.map { "- \($0.key): \($0.value)" + ($0.until.map { " (until \(QueryEngine.clock($0)))" } ?? "") }
        }
        let turns = await dialog.openTurns(since: today).suffix(verbatimTurns)
        if !turns.isEmpty, !lines.isEmpty { lines.append("Latest turns:") }
        lines += turns.map(line)
        return lines
    }

    static func line(_ turn: DialogTurn) -> String {
        let who: String
        switch turn.speaker {
        case .user: who = "user"
        case .muisti: who = "Muisti"
        case .proactive: who = "Muisti (by itself)"
        case .note: who = "Muisti (kept to itself)"
        }
        var s = "[\(QueryEngine.clock(turn.at))] \(who): \(turn.text.prefix(500))"
        if turn.looked { s += " [looked at the live view]" }
        if let tool = turn.tool, turn.speaker != .user { s += " [tool: \(tool)]" }
        if !turn.intentIDs.isEmpty { s += " [intent \(turn.intentIDs.map { "#" + $0 }.joined(separator: ", "))]" }
        if !turn.recordIDs.isEmpty { s += " [relied on record ids \(turn.recordIDs.prefix(8).map(String.init).joined(separator: ", "))]" }
        return s
    }

    private static let summarySystem = """
    You keep the running summary of a conversation between a user and Muisti, the assistant in \
    their camera glasses. Fold the turns below into three to six short sentences in English: \
    who asked for what, what Muisti promised or set up (reminders, rules, destinations, with \
    their #ids when given), what was decided, what the user told Muisti about themselves or \
    their plans. Keep every name, number, time and place exactly as it was said. Nothing that \
    was not said; no commentary.
    """

    /// Folds the oldest open turns into a summary once there are too many of them. The turns
    /// themselves stay in the database (and `recall_dialog` still finds them).
    static func summarizeIfNeeded(_ dialog: DialogStore, ai: NemotronClient, now: Date = Date()) async {
        let today = Calendar.current.startOfDay(for: now)
        let open = await dialog.openTurns(since: today)
        guard open.count > summarizeAbove, let first = open.first else { return }
        let batch = Array(open.prefix(summarizeBatch))
        guard let last = batch.last else { return }
        let text = batch.map(line).joined(separator: "\n")
        let summary = await LaneKind.$current.withValue(.background) {
            await withTimeout(seconds: 20) {
                try await ai.chat(system: summarySystem, user: text, maxTokens: 350, temperature: 0.1, background: true)
            }
        }
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
              await dialog.summarizedThrough < last.id else { return }
        await dialog.addSummary(from: first.id, to: last.id, level: "session", text: summary, at: last.at)
        Trace.note("dialog: turns \(first.id)–\(last.id) summarised (\(summary.count) characters)")
    }
}
