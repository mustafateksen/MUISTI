package com.muisti.engine

import org.json.JSONObject

/** What an app-side tool gives back: text for the model (it continues), or the final reply (the turn ends). */
sealed class ToolOut {
    data class Text(val text: String) : ToolOut()
    data class Final(val label: String, val text: String, val extra: JSONObject = JSONObject(), val used: List<Doc> = emptyList()) : ToolOut()
}

/** Context a tool handler can use: the turn's question, clock, memories, live frame, and evidence registration. */
class ToolCtx(val question: String, val now: Long, val docs: List<Doc>, val liveFrame: ByteArray?, val ev: (Doc) -> String)

/**
 * A tool that exists only in the Android app (notes, no-record zones, memory management, visual search...).
 * [schema] is one OpenAI tool object; [prompt] is one line added to the agent's instructions. The exported Python
 * prompts (docs/prompts.json) stay untouched.
 */
class ExtraTool(val name: String, val schema: String, val prompt: String, val run: (JSONObject, ToolCtx) -> ToolOut) {
    companion object {
        /** Builds the OpenAI function schema text with key order kept. */
        fun function(name: String, description: String, parameters: String) =
            "{\"type\": \"function\", \"function\": {\"name\": \"$name\", \"description\": ${JSONObject.quote(description)}, \"parameters\": $parameters}}"

        /** prompts.agentTools + extras, as one tools array (schema text spliced to keep key order). */
        fun merge(base: RawJson, extras: List<ExtraTool>): RawJson {
            if (extras.isEmpty()) return base
            val t = base.text.trimEnd()
            require(t.endsWith("]")) { "AGENT_TOOLS must be a JSON array" }
            return RawJson(t.dropLast(1).trimEnd() + ", " + extras.joinToString(", ") { it.schema } + "]")
        }
    }
}

/**
 * Speech fixes that do not need the model: the recognizer sometimes returns ONE hearing of "note it" as "not eat"
 * (defect D4). With alternatives the agent picks the sensible one itself; a bare known mishearing is fixed here.
 * Only whole short utterances are touched, so real sentences ("not that one", "now it's raining") pass unchanged.
 */
object SpeechFix {
    private val NOTE_IT = Regex("""^(?:not|knot|nought|no|note|nod|now)[ -]?(?:eat|it|ate|at|eats|tit|edit)[.!]?$""", RegexOption.IGNORE_CASE)
    private val NOTE_THAT = Regex("""^(?:not|knot|nought|note)[ -]?(?:dat|dad|det)[.!]?$""", RegexOption.IGNORE_CASE)

    /** Returns the corrected question, or [heard] unchanged. */
    fun correct(heard: String, alternatives: List<String>): String {
        val t = heard.trim()
        if (alternatives.any { it.isNotBlank() && !it.trim().equals(t, ignoreCase = true) }) return heard
        return when {
            NOTE_IT.matches(t) && !t.equals("note it", true) -> "note it"
            NOTE_THAT.matches(t) -> "note that"
            else -> heard
        }
    }
}
