import Foundation

/// Turns a request the user typed on the Safety page ("ocağı açık bırakırsam uyar") into one
/// rule. Same rule fields and schema as the voice `create_rule` tool (`SafetyPrompts.ruleGuide`), so a typed
/// rule behaves exactly like a spoken one; the model also rewrites the request as the rule's
/// one-sentence summary.
enum SafetyRuleWriter {
    enum Failure: LocalizedError {
        case noKey
        case notARule

        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Add an API key in Settings first. Muisti needs it to write the rule.")
            case .notARule: String(localized: "Muisti couldn't turn that into a rule. Say what to watch and when.")
            }
        }
    }

    static func draft(_ request: String, ai: NemotronClient, now: Date = Date()) async throws -> SafetyRule {
        guard await ai.hasKey else { throw Failure.noKey }
        let user = """
        Current local time: \(QueryEngine.promptTime(now))
        Request: \(request)
        """
        do {
            return try await ai.chatJSON(SafetyRule.self, system: system, user: user, jsonSchema: SafetyPrompts.ruleObjectSchema,
                                         schemaName: "rule", maxTokens: 700, temperature: 0)
        } catch NemotronClient.NemotronError.badResponse {
            throw Failure.notARule
        }
    }

    static let system = """
    You turn one request that the user typed into Muisti's Safety page into exactly one safety \
    rule. Muisti sees what the user sees through smart glasses and warns or reminds them. The \
    request may be short, informal, misspelled and in any language: work out what they want \
    watched and when. "summary" is the request rewritten as one clear, natural sentence in the \
    request's language, as the user would say it ("Warn me if I leave home with the stove on."). \
    Output only the JSON object.

    """ + ruleFields

    /// The rule field definitions shared with the voice `create_rule` tool.
    private static var ruleFields: String { SafetyPrompts.ruleGuide }
}
