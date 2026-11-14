package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * One short summary per CLOSED episode, written once in the background from the stored structured text (never
 * images): one Nemotron call. Every sentence must cite memory ids; code then drops any sentence that cites nothing
 * or whose numbers (phones, hours, prices) are not all written in ONE cited memory — the same rule as answers.
 */
class EpisodeSummarizer(private val llm: Llm) {
    var calls = 0; private set
    /** Sentences the last verification removed (for logs and tests). */
    var lastDropped: List<String> = emptyList(); private set

    companion object {
        const val PROMPT = """You summarise one stretch of the user's day from memories their smart glasses stored.
Write 1-3 short sentences in English, like a diary line: where they were and the most useful things they saw
(names on signs, opening hours, prices, notes). Every sentence must list the ids (M1, M2, ...) of the memories it uses.
Copy numbers exactly as written in a memory and never combine numbers from different memories. Do not guess."""
        val SCHEMA = RawJson("""{"type": "object", "properties": {"sentences": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "memories": {"type": "array", "items": {"type": "string"}}}, "required": ["text", "memories"]}}}, "required": ["sentences"]}""")
        private val NUM = Regex("""\d+""")

        /** Keeps only cited sentences whose numbers all appear in one cited memory (times of a memory count). */
        fun verify(raw: JSONObject, items: List<Doc>): Pair<String, List<String>> {
            val hhmm = SimpleDateFormat("HH:mm", Locale.US)
            val kept = ArrayList<String>(); val dropped = ArrayList<String>()
            for (s in raw.arr("sentences").objects()) {
                val raw0 = s.str("text")?.trim() ?: continue
                // citations may also come inline ("... [M1]" / "(M1, M2)"): used, then removed from the shown text
                val inline = Regex("""M\d+""").findAll(Regex("""[\[(]\s*M\d+(?:\s*,\s*M\d+)*\s*[\])]""").findAll(raw0).joinToString(" ") { it.value }).map { it.value }.toList()
                val text = raw0.replace(Regex("""\s*[\[(]\s*M\d+(?:\s*,\s*M\d+)*\s*[\])]"""), "").trim()
                val cited = (s.arr("memories").strings() + inline).distinct().mapNotNull { id ->
                    Regex("""M(\d+)""").matchEntire(id.trim())?.groupValues?.get(1)?.toInt()?.let { items.getOrNull(it - 1) } }
                val nums = NUM.findAll(text.replace(Regex("""\b(\d{1,2})[:.]00\b"""), "$1")).map { it.value }.toSet()
                val backed = cited.isNotEmpty() && (nums.isEmpty() || cited.any { d ->
                    NUM.findAll(d.text + " " + hhmm.format(Date(d.seenAt))).map { it.value }.toSet().containsAll(nums) })
                if (backed) kept.add(text) else dropped.add(text)
            }
            return kept.joinToString(" ") to dropped
        }
    }

    /** Null when nothing verifiable is left (the episode then shows its plain headline). */
    fun summarize(e: Episode, items: List<Doc>): String? {
        if (items.isEmpty()) return null
        val f = SimpleDateFormat("HH:mm", Locale.US)
        val lines = items.take(24).mapIndexed { i, d -> "M${i + 1} (${f.format(Date(d.seenAt))}): ${d.text.take(400)}" }
        val user = "Episode ${f.format(Date(e.start))}-${f.format(Date(e.end))}${e.place?.let { " on $it" } ?: ""}.\nMEMORIES:\n" + lines.joinToString("\n")
        calls++
        val raw = llm.jsonCall(PROMPT, user, SCHEMA, "episode_summary", 300)
        val (kept, dropped) = verify(raw, items.take(24))
        if (dropped.isNotEmpty()) lastDropped = dropped
        return kept.ifEmpty { null }
    }
}

/** summaries.json: episode id -> summary, valid while the episode keeps the same members. */
class SummaryStore(dir: File) {
    private val file = File(dir, "summaries.json")
    private val lock = Any()
    private var map: MutableMap<String, Pair<String, String>>? = null   // id -> (member hash, text)

    private fun load(): MutableMap<String, Pair<String, String>> = map ?: runCatching {
        val j = JSONObject(file.readText())
        j.keys().asSequence().associateWith { k -> j.getJSONObject(k).let { it.getString("h") to it.getString("t") } }.toMutableMap()
    }.getOrDefault(HashMap()).also { map = it }

    fun hash(e: Episode) = e.members.joinToString(",").hashCode().toString(16)

    fun get(e: Episode): String? = synchronized(lock) { load()[e.id]?.takeIf { it.first == hash(e) }?.second }

    fun put(e: Episode, text: String) = synchronized(lock) {
        load()[e.id] = hash(e) to text
        file.writeText(JSONObject().apply { for ((k, v) in load()) put(k, JSONObject().put("h", v.first).put("t", v.second)) }.toString())
    }

    /** Summaries of [eps] that are still valid ("" = tried, nothing verifiable: not shown, not retried). */
    fun valid(eps: List<Episode>): Map<String, String> = eps.mapNotNull { e -> get(e)?.takeIf { it.isNotEmpty() }?.let { e.id to it } }.toMap()
}
