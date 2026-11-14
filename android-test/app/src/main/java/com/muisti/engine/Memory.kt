package com.muisti.engine

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Port of store.py, on the phone: frames.jsonl (one verified record per line) + JPEGs in [dir].
 * Sightings are derived with Merge (cached until the next write), like the Python store.
 */
class MemoryStore(private val dir: File) {
    private val framesFile = File(dir, "frames.jsonl")
    val frameDir = File(dir, "frames").apply { mkdirs() }
    private val lock = Any()
    private var rows: MutableList<JSONObject>? = null
    private var cache: List<JSONObject>? = null

    private fun load(): MutableList<JSONObject> {
        rows?.let { return it }
        val out = ArrayList<JSONObject>()
        if (framesFile.exists()) framesFile.forEachLine { if (it.isNotBlank()) runCatching { out.add(JSONObject(it)) } }
        rows = out
        return out
    }

    fun addFrame(seenAtMs: Long, record: JSONObject, ocrLines: List<String>, jpeg: ByteArray, dhash: Long?): Int = synchronized(lock) {
        val all = load()
        val id = (all.maxOfOrNull { it.optInt("id") } ?: 0) + 1
        File(frameDir, "$id.jpg").writeBytes(jpeg)
        val row = JSONObject().put("id", id).put("seen_at", seenAtMs).put("ocr_lines", JSONArray(ocrLines))
            .put("record", record).put("dhash", nullable(dhash))
        framesFile.appendText(row.toString() + "\n")
        all.add(row)
        cache = null
        id
    }

    fun sightings(): List<JSONObject> = synchronized(lock) {
        cache?.let { return it }
        val all = load().sortedBy { it.optLong("seen_at") }
        val frames = all.map { Frame(it.optLong("seen_at") / 1000.0, "${it.optInt("id")}.jpg", it.getJSONObject("record"),
            if (it.isNull("dhash")) null else it.optLong("dhash")) }
        val byFile = all.associateBy { "${it.optInt("id")}.jpg" }
        val out = Merge.mergeSightings(frames).mapIndexed { i, s ->
            val first = byFile[s.arr("frames").getString(0)]!!
            s.put("id", i + 1).put("seen_at", first.optLong("seen_at")).put("source", "live").put("frame_dir", frameDir.path)
        }
        cache = out
        out
    }

    /** "Forget the last N minutes": delete everything seen at or after [sinceMs]. */
    fun forget(sinceMs: Long): Int = synchronized(lock) {
        val all = load()
        val gone = all.filter { it.optLong("seen_at") >= sinceMs }
        gone.forEach { File(frameDir, "${it.optInt("id")}.jpg").delete() }
        all.removeAll(gone.toSet())
        framesFile.writeText(all.joinToString("") { it.toString() + "\n" })
        cache = null
        gone.size
    }

    fun frameCount() = synchronized(lock) { load().size }
}

/** Port of embed.py: nemotron-3.5-embed-1b, passage/query, batches of 32, unit vectors, cached by (kind, text). */
class Embedder(private val key: String, private val cacheFile: File?) {
    private val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()
    private val cache = HashMap<String, FloatArray>()
    private val lock = Any()

    init {
        cacheFile?.takeIf { it.exists() }?.forEachLine { l ->
            val tab = l.indexOf('\t')
            if (tab > 0) cache[l.substring(0, tab)] = l.substring(tab + 1).split(',').map { it.toFloat() }.toFloatArray()
        }
    }

    fun available() = key.isNotEmpty()

    private fun k(kind: String, text: String): String {
        val d = MessageDigest.getInstance("SHA-1").digest("$kind\n$text".toByteArray())
        return d.joinToString("") { "%02x".format(it) }
    }

    fun embed(texts: List<String>, kind: String): List<FloatArray>? {
        if (!available() || texts.isEmpty()) return null
        synchronized(lock) {
            val missing = texts.distinct().filter { k(kind, it) !in cache }
            try {
                for (batch in missing.chunked(32)) {
                    val body = JSONObject().put("model", "nvidia/nemotron-3.5-embed-1b").put("input", JSONArray(batch))
                        .put("input_type", kind).put("encoding_format", "float").put("truncate", "END")
                    val req = Request.Builder().url("https://integrate.api.nvidia.com/v1/embeddings")
                        .header("Authorization", "Bearer $key")
                        .post(body.toString().toRequestBody("application/json".toMediaType())).build()
                    http.newCall(req).execute().use { resp ->
                        if (!resp.isSuccessful) throw RuntimeException("embed HTTP ${resp.code}")
                        val data = JSONObject(resp.body!!.string()).getJSONArray("data").objects().sortedBy { it.optInt("index") }
                        for ((t, item) in batch.zip(data)) {
                            val e = item.getJSONArray("embedding")
                            val v = FloatArray(e.length()) { e.getDouble(it).toFloat() }
                            var n = 0.0; for (x in v) n += x * x
                            val norm = maxOf(Math.sqrt(n), 1e-8).toFloat()
                            for (i in v.indices) v[i] /= norm
                            cache[k(kind, t)] = v
                            cacheFile?.appendText(k(kind, t) + "\t" + v.joinToString(",") + "\n")
                        }
                    }
                }
            } catch (e: Exception) {
                if (missing.isNotEmpty()) return null
            }
            return texts.map { cache[k(kind, it)]!! }
        }
    }
}
