package com.muisti.capture

import com.muisti.engine.Obs
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A frame that could not be ingested because the network was down. The JPEG is the already-redacted one. */
class PendingFrame(val id: String, val jpeg: ByteArray, val obs: List<Obs>, val seenAt: Long, val dhash: Long?,
                   val lat: Double?, val lon: Double?, val street: String?, val vec: FloatArray? = null)

/**
 * Frames waiting for the network, on disk (they survive the app being killed). Oldest first; when full, the oldest
 * is dropped (memory follows the present, like the live upload queue). Pure Kotlin.
 */
class PendingQueue(private val dir: File, private val max: Int = 300) {
    init { dir.mkdirs() }
    private val lock = Any()

    fun add(f: PendingFrame) = synchronized(lock) {
        val meta = JSONObject().put("seen_at", f.seenAt).put("dhash", f.dhash ?: JSONObject.NULL)
            .put("lat", f.lat ?: JSONObject.NULL).put("lon", f.lon ?: JSONObject.NULL).put("street", f.street ?: JSONObject.NULL)
            .put("vec", f.vec?.let { v -> JSONArray(v.map { it.toDouble() }) } ?: JSONObject.NULL)
            .put("obs", JSONArray(f.obs.map { JSONArray().put(it.text).put(it.conf).put(it.x).put(it.y).put(it.w).put(it.h) }))
        val name = "%015d-%s".format(f.seenAt, f.id)
        File(dir, "$name.jpg").writeBytes(f.jpeg)
        File(dir, "$name.json.tmp").apply { writeText(meta.toString()) }.renameTo(File(dir, "$name.json"))   // json last = complete entry
        val all = names()
        all.take(maxOf(0, all.size - max)).forEach { remove(it) }
    }

    fun size() = synchronized(lock) { names().size }

    fun oldest(): PendingFrame? = synchronized(lock) {
        val n = names().firstOrNull() ?: return null
        runCatching {
            val m = JSONObject(File(dir, "$n.json").readText())
            val o = m.getJSONArray("obs")
            PendingFrame(n, File(dir, "$n.jpg").readBytes(),
                (0 until o.length()).map { o.getJSONArray(it) }.map { Obs(it.getString(0), it.getDouble(1), it.getDouble(2), it.getDouble(3), it.getDouble(4), it.getDouble(5)) },
                m.getLong("seen_at"), if (m.isNull("dhash")) null else m.getLong("dhash"),
                if (m.isNull("lat")) null else m.getDouble("lat"), if (m.isNull("lon")) null else m.getDouble("lon"),
                if (m.isNull("street")) null else m.getString("street"),
                m.optJSONArray("vec")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } })
        }.getOrElse { remove(n); null }       // a broken entry is dropped, never retried forever
    }

    fun remove(id: String) = synchronized(lock) { File(dir, "$id.json").delete(); File(dir, "$id.jpg").delete(); Unit }

    /** Everything pending from [sinceMs] on is deleted ("forget the last N minutes" must reach the queue too). */
    fun forgetSince(sinceMs: Long) = synchronized(lock) { names().filter { it.substringBefore('-').toLong() >= sinceMs }.forEach { remove(it) } }

    private fun names() = (dir.listFiles() ?: emptyArray()).filter { it.name.endsWith(".json") }.map { it.name.removeSuffix(".json") }.sorted()
}

/** What happened to one queued frame when it was tried again. */
enum class Outcome { SENT, DROPPED, RETRY_LATER }

/**
 * Empties the queue after the network comes back, ONE frame at a time with a pause between them, so a long offline
 * spell does not turn into a request storm. Every retry goes through the normal ingest, i.e. through the privacy
 * gate again. A RETRY_LATER (still offline / server down) stops this round.
 */
class Drainer(private val queue: PendingQueue, private val pauseMs: Long = 1500, private val sleep: (Long) -> Unit = { Thread.sleep(it) }) {
    fun drain(isOnline: () -> Boolean, send: (PendingFrame) -> Outcome, maxFrames: Int = Int.MAX_VALUE): Int {
        var done = 0
        while (done < maxFrames && isOnline()) {
            val f = queue.oldest() ?: break
            when (runCatching { send(f) }.getOrDefault(Outcome.RETRY_LATER)) {
                Outcome.SENT, Outcome.DROPPED -> { queue.remove(f.id); done++ }
                Outcome.RETRY_LATER -> return done
            }
            if (queue.size() > 0) sleep(pauseMs)
        }
        return done
    }
}
