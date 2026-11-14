package com.muisti.engine

import org.json.JSONObject
import java.io.File

/**
 * Things the user asked MUISTI to note ("note it", "note that my car is on level 3", "remember this").
 * One JSON line per note; a note can carry the frame the user was looking at. Notes are searched
 * like memories (they become Docs), so "where did I park?" finds "My car is on level 3".
 */
class NoteStore(private val file: File) {
    class Note(val text: String, val at: Long, val frame: String?)

    private val lock = Any()
    @Volatile var version = 0; private set
    private var cache: List<Note>? = null

    fun all(): List<Note> = synchronized(lock) {
        cache ?: (if (file.exists()) file.readLines().mapNotNull { l ->
            runCatching { JSONObject(l).let { Note(it.getString("text"), it.getLong("at"), it.optString("frame").ifEmpty { null }) } }.getOrNull()
        } else emptyList()).also { cache = it }
    }

    fun add(text: String, at: Long, frame: String?) = synchronized(lock) {
        file.parentFile?.mkdirs()
        file.appendText(JSONObject().put("text", text).put("at", at).put("frame", frame ?: "").toString() + "\n")
        cache = null; version++
    }

    /** "forget the last N minutes" also removes notes made in that time. */
    fun forget(sinceMs: Long): Int = synchronized(lock) {
        val keep = all().filter { it.at < sinceMs }
        val gone = all().size - keep.size
        if (gone > 0) {
            file.writeText(keep.joinToString("") { JSONObject().put("text", it.text).put("at", it.at).put("frame", it.frame ?: "").toString() + "\n" })
            cache = null; version++
        }
        gone
    }

    fun docs(frameDir: String?): List<Doc> = all().map {
        Doc("note", it.at, it.frame, if (it.frame != null) frameDir else null, "note", false, "note", "note",
            text = "NOTE the user asked you to keep: ${it.text}")
    }
}
