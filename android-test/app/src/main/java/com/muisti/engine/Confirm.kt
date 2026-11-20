package com.muisti.engine

import org.json.JSONObject

/**
 * Actions the agent may only PROPOSE: they run after the user confirms by tap or by voice ("yes" / "no").
 * [action] is the payload the app executes; [frames] are thumbnails shown on the card (e.g. what would be deleted).
 */
class PendingAction(val id: String, val kind: String, val question: String, val action: JSONObject,
                    val count: Int = 0, val frames: List<String> = emptyList()) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("kind", kind).put("question", question).put("action", action)
        .put("count", count).put("frames", org.json.JSONArray(frames))

    companion object {
        const val LABEL = "CONFIRM"
        fun fromJson(j: JSONObject) = PendingAction(j.getString("id"), j.getString("kind"), j.getString("question"),
            j.getJSONObject("action"), j.optInt("count"), j.arr("frames").strings())

        fun propose(kind: String, question: String, action: JSONObject, count: Int = 0, frames: List<String> = emptyList()) =
            ToolOut.Final(LABEL, question, JSONObject().put("pending",
                PendingAction(java.util.UUID.randomUUID().toString().take(8), kind, question, action, count, frames).toJson()))
    }
}

/** Spoken replies to a confirmation question. Null = not a yes/no answer (the pending action is dropped). */
object Confirmations {
    private val YES = Regex("""^(yes|yeah|yep|yup|sure|ok|okay|do it|confirm|confirmed|go ahead|please do|correct|kyllä|joo|evet)(?=$|[\s,.!?])""", RegexOption.IGNORE_CASE)
    // explicit end instead of \b: Java's \b treats ä / ı as non-word characters
    private val NO = Regex("""^(no|nope|cancel|don't|do not|stop|never mind|nevermind|wait|ei|hayır)(?=$|[\s,.!?])""", RegexOption.IGNORE_CASE)

    fun answer(text: String): Boolean? {
        val t = text.trim().trimEnd('.', '!')
        return when { NO.containsMatchIn(t) -> false; YES.containsMatchIn(t) -> true; else -> null }
    }
}

/** `create_zone`: "don't record at home" -> a no-record zone around the current position, after confirmation. */
fun createZoneTool(here: () -> Triple<Double, Double, String?>?): ExtraTool = ExtraTool("create_zone",
    ExtraTool.function("create_zone", "Propose a no-record zone around the user's CURRENT position (\"don't record at home\", \"never record here\"). The user must confirm.",
        """{"type": "object", "properties": {"name": {"type": "string", "description": "short name, e.g. 'Home', 'Office', 'Doctor'"}, "radius_m": {"type": "number", "description": "radius in metres, default 150"}}, "required": ["name"]}"""),
    "- create_zone: the user wants a place where nothing is recorded (\"don't record at home\"). It needs confirmation; it uses where they are now.") { a, _ ->
    val pos = here()
    if (pos == null) ToolOut.Text("No location right now: tell the user to allow location (or add the zone in Privacy settings when there).")
    else {
        val name = a.str("name")?.trim()?.ifEmpty { null } ?: "this place"
        val r = a.num("radius_m", 150.0).coerceIn(30.0, 2000.0)
        PendingAction.propose("create_zone", "Should I stop recording within ${r.toInt()} metres of here and call it $name?",
            JSONObject().put("type", "create_zone").put("name", name).put("radius_m", r).put("lat", pos.first).put("lon", pos.second))
    }
}
