package com.muisti.engine

import org.json.JSONObject
import java.io.File

/** Something the user explicitly asked to remember ("note it", "note that my car is on level 3"). */
class Note(val id: Int, val createdAt: Long, val text: String, val frame: String?, val lat: Double?, val lon: Double?, val street: String?)

/**
 * "note it": notes live next to the visual memory (notes.jsonl + optional frame JPEG, already redacted by the app).
 * They are searchable like memories (type "note") and can be deleted like them. Pure Kotlin.
 */
class NoteStore(private val dir: File) {
    private val file = File(dir, "notes.jsonl")
    val frameDir = File(dir, "note_frames").apply { mkdirs() }
    private val lock = Any()
    @Volatile var version = 0; private set

    fun add(text: String, now: Long, jpeg: ByteArray? = null, lat: Double? = null, lon: Double? = null, street: String? = null): Note = synchronized(lock) {
        val id = (all().maxOfOrNull { it.id } ?: 0) + 1
        val frame = jpeg?.let { "n$id.jpg".also { f -> File(frameDir, f).writeBytes(jpeg) } }
        val n = Note(id, now, text.trim(), frame, lat, lon, street)
        file.appendText(toJson(n).toString() + "\n")
        version++
        n
    }

    fun all(): List<Note> = synchronized(lock) {
        if (!file.exists()) return emptyList()
        file.readLines().filter { it.isNotBlank() }.mapNotNull { runCatching { fromJson(JSONObject(it)) }.getOrNull() }
    }

    /** Deletes notes (and their frames). Returns how many. */
    fun delete(ids: Set<Int>): Int = synchronized(lock) {
        val keep = all().filter { it.id !in ids }
        val gone = all().filter { it.id in ids }
        gone.forEach { n -> n.frame?.let { File(frameDir, it).delete() } }
        file.writeText(keep.joinToString("") { toJson(it).toString() + "\n" })
        if (gone.isNotEmpty()) version++
        gone.size
    }

    fun forgetSince(sinceMs: Long) = delete(all().filter { it.createdAt >= sinceMs }.map { it.id }.toSet())

    /** Notes as search documents: quotes from a note verify against the user's own words. */
    fun docs(): List<Doc> = all().map { n ->
        Doc("note", n.createdAt, n.frame, frameDir.path, "note", false, n.text.take(60), "note",
            text = "Note the user asked to remember: ${n.text}" + (n.street?.let { ". Noted on $it" } ?: "")).apply {
            lat = n.lat; lon = n.lon; street = n.street
        }
    }

    private fun toJson(n: Note) = JSONObject().put("id", n.id).put("created_at", n.createdAt).put("text", n.text)
        .put("frame", nullable(n.frame)).put("lat", nullable(n.lat)).put("lon", nullable(n.lon)).put("street", nullable(n.street))

    private fun fromJson(j: JSONObject) = Note(j.getInt("id"), j.getLong("created_at"), j.getString("text"), j.str("frame"),
        if (j.isNull("lat")) null else j.optDouble("lat"), if (j.isNull("lon")) null else j.optDouble("lon"), j.str("street"))
}

/** The `note` agent tool. [save] stores the note (with the redacted live view when asked) and returns it. */
fun noteTool(save: (text: String, withView: Boolean) -> Note?): ExtraTool = ExtraTool("note",
    ExtraTool.function("note", "Save something the user explicitly asks you to remember (\"note it\", \"note that ...\", \"remember this\").",
        """{"type": "object", "properties": {"text": {"type": "string", "description": "what to remember, as a short standalone sentence in the user's words; for 'note it' describe what was just discussed or what the camera shows"}, "include_view": {"type": "boolean", "description": "true for 'note it' / 'remember this' about what the user is looking at"}}, "required": ["text", "include_view"]}"""),
    "- note: the user asks you to remember something (\"note it\", \"note that ...\", \"remember this\"). Speech often turns \"note it\" into \"not eat\".") { a, _ ->
    val text = a.str("text")?.trim().orEmpty()
    if (text.isEmpty()) ToolOut.Text("Not saved: give the text to remember.")
    else {
        val n = save(text, a.bool("include_view"))
        if (n == null) ToolOut.Text("Not saved: storage failed.")
        else ToolOut.Final("NOTED", "Okay, noted: ${n.text.trimEnd('.')}.", JSONObject().put("note_id", n.id))
    }
}
