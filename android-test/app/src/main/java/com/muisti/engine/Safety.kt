package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** "Warn me if I see ...": phrases matched on a memory's stored text (OCR, sign text, objects), any language. */
data class SafetyRule(val id: String, val name: String, val phrases: List<String>, val message: String, val builtIn: Boolean = false,
                      val unless: List<String> = emptyList()) {
    private val rx by lazy { phrases.map { Regex("(?<![\\p{L}])" + Regex.escape(it.lowercase()).replace("\\ ", "\\s+") + "(?![\\p{L}])") } }
    private val nx by lazy { unless.map { Regex("(?<![\\p{L}])" + Regex.escape(it.lowercase()) + "(?![\\p{L}])") } }
    fun matches(text: String): String? {
        val t = text.lowercase()
        if (nx.any { it.containsMatchIn(t) }) return null
        return phrases.zip(rx).firstOrNull { it.second.containsMatchIn(t) }?.first
    }
    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("phrases", JSONArray(phrases)).put("message", message)
        .put("unless", JSONArray(unless))

    companion object {
        fun fromJson(j: JSONObject) = SafetyRule(j.getString("id"), j.getString("name"), j.arr("phrases").strings(), j.getString("message"),
            false, j.arr("unless").strings())

        val BUILT_IN = listOf(
            SafetyRule("wet_floor", "Wet floor", listOf("wet floor", "slippery", "märkä lattia", "liukas", "halka", "våt golv", "caution wet"),
                "Careful: wet floor sign.", true),
            SafetyRule("do_not_enter", "Do not enter", listOf("do not enter", "no entry", "authorized personnel only", "authorised personnel only",
                "staff only", "no trespassing", "pääsy kielletty", "asiattomilta pääsy kielletty", "ei pääsyä", "tillträde förbjudet"),
                "That area is marked do not enter.", true),
            SafetyRule("hazard", "Hazard sign", listOf("danger", "high voltage", "biohazard", "hazardous", "toxic", "vaara", "hengenvaara",
                "korkeajännite", "fara", "risk of electric shock", "falling objects", "construction site"),
                "Hazard sign ahead.", true, unless = listOf("danger zone", "dangerous liaisons", "album", "film", "movie", "concert", "non-toxic", "not toxic")),
            SafetyRule("fire_exit", "Emergency exit", listOf("emergency exit", "fire exit", "hätäuloskäytävä", "hätäuloskäynti", "nödutgång"),
                "Emergency exit here.", true),
        )
    }
}

class SafetyHit(val rule: SafetyRule, val phrase: String, val doc: Doc)

/**
 * The safety monitor: new memories are checked against the rules on their stored TEXT first (no model call); only a
 * text hit may ask the stored frame ([imageCheck], one look through the privacy gate) to confirm it. Each confirmed
 * hit becomes a SAFETY notice with the evidence frame; the same rule at the same place is not repeated within 10 min.
 */
class SafetyMonitor(private val rules: () -> List<SafetyRule>, private val imageCheck: ((Doc, SafetyRule) -> Boolean?)? = null,
                    private val maxChecksPerMin: Int = 20) {
    private val lastAlert = HashMap<String, Long>()
    private val checks = ArrayDeque<Long>()

    companion object { const val REPEAT_MS = 10 * 60_000L }

    fun textHits(d: Doc): List<SafetyHit> = rules().mapNotNull { r -> r.matches(d.text)?.let { SafetyHit(r, it, d) } }

    private fun scene(d: Doc) = d.street ?: d.lat?.let { "%.3f,%.3f".format(it, d.lon) } ?: "t${d.seenAt / REPEAT_MS}"

    fun evaluate(newDocs: List<Doc>, now: Long): List<Notice> {
        val out = ArrayList<Notice>()
        for (d in newDocs.filter { it.type == "sighting" }) for (h in textHits(d)) {
            val key = "${h.rule.id}@${scene(d)}"
            if ((lastAlert[key] ?: Long.MIN_VALUE / 2) > d.seenAt - REPEAT_MS) continue
            // image check only for text hits, rate-capped; unknown (null / no budget) keeps the text verdict
            val confirmed = imageCheck?.let { chk ->
                while ((checks.firstOrNull() ?: now) < now - 60_000) checks.removeFirst()
                if (checks.size >= maxChecksPerMin) null else { checks.addLast(now); runCatching { chk(d, h.rule) }.getOrNull() }
            }
            if (confirmed == false) continue
            lastAlert[key] = d.seenAt
            out.add(Notice("safety-$key-${d.seenAt}", Notice.SAFETY, "safety:$key:${d.seenAt / REPEAT_MS}", h.rule.message,
                "Seen \"${h.phrase}\" on a sign${d.street?.let { " on $it" } ?: ""}.", now, 1.0, listOfNotNull(d.frame)))
        }
        return out
    }
}

/** User rules (safety_rules.json); built-ins are always on. */
class SafetyRuleStore(dir: File) {
    private val file = File(dir, "safety_rules.json")
    fun user(): List<SafetyRule> = runCatching { JSONArray(file.readText()).objects().map { SafetyRule.fromJson(it) } }.getOrDefault(emptyList())
    fun all(): List<SafetyRule> = SafetyRule.BUILT_IN + user()
    fun add(r: SafetyRule) { file.writeText(JSONArray((user().filter { it.id != r.id } + r).map { it.toJson() }).toString()) }
    fun remove(id: String) { file.writeText(JSONArray(user().filter { it.id != id }.map { it.toJson() }).toString()) }
}

/** `add_safety_rule`: "warn me if I see a wet floor sign" -> preview of what will be watched, saved after a yes. */
fun safetyRuleTool(): ExtraTool = ExtraTool("add_safety_rule",
    ExtraTool.function("add_safety_rule", "Propose a rule to warn the user when a sign or thing is seen (\"warn me if I see a wet floor sign\"). The user confirms a preview.",
        """{"type": "object", "properties": {"name": {"type": "string", "description": "short name, e.g. 'Peanuts'"}, "phrases": {"type": "array", "items": {"type": "string"}, "description": "2-8 words or short phrases that would be WRITTEN on such a sign or label, in English and Finnish"}, "message": {"type": "string", "description": "what to say when it is seen, one short sentence"}}, "required": ["name", "phrases", "message"]}"""),
    "- add_safety_rule: the user asks to be warned when they see something (\"warn me if I see ...\"). It needs confirmation.") { a, _ ->
    val phrases = a.arr("phrases").strings().map { it.trim().lowercase() }.filter { it.length >= 3 }.distinct().take(8)
    val name = a.str("name")?.trim()?.ifEmpty { null } ?: phrases.firstOrNull()
    if (phrases.isEmpty() || name == null) ToolOut.Text("Not proposed: give the words that would be written on it.")
    else PendingAction.propose("add_safety_rule", "I'll warn you when I read: ${phrases.joinToString(", ")}. Should I add this rule?",
        JSONObject().put("type", "add_safety_rule").put("rule", SafetyRule("user_" + name.lowercase().replace(Regex("[^a-z0-9]+"), "_"),
            name, phrases, a.str("message") ?: "Heads up: $name.").toJson()))
}
