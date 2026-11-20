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
    /** MobileCLIP image vector per frame id (visual search); deleted with the frame. */
    val vectors = ImageVectors(File(dir, "image_vectors.bin"))
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

    fun addFrame(seenAtMs: Long, record: JSONObject, ocrLines: List<String>, jpeg: ByteArray, dhash: Long?,
                 lat: Double? = null, lon: Double? = null, street: String? = null, imageVec: FloatArray? = null): Int = synchronized(lock) {
        val all = load()
        val id = (all.maxOfOrNull { it.optInt("id") } ?: 0) + 1
        File(frameDir, "$id.jpg").writeBytes(jpeg)
        val row = JSONObject().put("id", id).put("seen_at", seenAtMs).put("ocr_lines", JSONArray(ocrLines))
            .put("record", record).put("dhash", nullable(dhash))
            .put("lat", nullable(lat)).put("lon", nullable(lon)).put("street", nullable(street))
        framesFile.appendText(row.toString() + "\n")
        all.add(row)
        imageVec?.let { vectors.put(id, it) }
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
            // where: the first frame of the sighting that had a fix
            frames.zip(all).firstOrNull { (fr, row) -> fr.file in s.arr("frames").strings() && !row.isNull("lat") && row.has("lat") }?.second?.let {
                s.put("lat", it.getDouble("lat")).put("lon", it.getDouble("lon")).put("street", it.opt("street"))
            }
            s
        }
        cache = out
        out
    }

    fun frameIds(): List<Int> = synchronized(lock) { load().map { it.optInt("id") }.sorted() }

    fun frameBytes(id: Int): ByteArray? = File(frameDir, "$id.jpg").takeIf { it.exists() }?.readBytes()

    /** Deletes frames by id: the record line and the JPEG. Returns how many records were removed. */
    fun deleteFrames(ids: Set<Int>): Int = synchronized(lock) {
        if (ids.isEmpty()) return 0
        val all = load()
        val gone = all.filter { it.optInt("id") in ids }
        ids.forEach { File(frameDir, "$it.jpg").delete() }
        vectors.delete(ids)
        if (gone.isEmpty()) return 0
        all.removeAll(gone.toSet())
        framesFile.writeText(all.joinToString("") { it.toString() + "\n" })
        cache = null
        gone.size
    }

    /** "Forget the last N minutes": delete everything seen at or after [sinceMs]. */
    fun forget(sinceMs: Long): Int = synchronized(lock) {
        val all = load()
        val gone = all.filter { it.optLong("seen_at") >= sinceMs }
        gone.forEach { File(frameDir, "${it.optInt("id")}.jpg").delete() }
        vectors.delete(gone.map { it.optInt("id") }.toSet())
        all.removeAll(gone.toSet())
        framesFile.writeText(all.joinToString("") { it.toString() + "\n" })
        cache = null
        gone.size
    }

    fun frameCount() = synchronized(lock) { load().size }
}

/**
 * Port of embed.py: nemotron-3.5-embed on MUISTI's Verda retrieval deployment (POST {retrievalUrl}/v2/embed),
 * document/query, batches of 32, unit vectors, cached by (kind, text). "passage" (the Python name) is sent as
 * "document". The cache file name carries the model so vectors of different models never share an index.
 */
class Embedder(private val keyOf: () -> String, private val cacheFile: File?,
               private val retrievalUrlOf: () -> String = { DEFAULT_RETRIEVAL_URL }) {
    constructor(key: String, cacheFile: File?, retrievalUrl: String = DEFAULT_RETRIEVAL_URL) : this({ key }, cacheFile, { retrievalUrl })
    private val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()
    // most recently used last; trimmed to MAX_CACHE (the old text cache grew to 180 MB and froze app start for ~27 s)
    private val cache = LinkedHashMap<String, FloatArray>(1024, 0.75f, true)
    private val lock = Any()
    private val binFile = cacheFile?.let { File(it.parentFile, it.nameWithoutExtension + ".bin") }
    private var loaded = false

    /** Binary cache: [key UTF][dim int][dim floats]... Read on first use (a background thread), never at construction. */
    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        cacheFile?.takeIf { it.exists() && it.extension == "tsv" }?.delete()     // old, slow text format: rebuilt on demand
        val f = binFile?.takeIf { it.exists() } ?: return
        var count = 0
        runCatching {
            java.io.DataInputStream(java.io.BufferedInputStream(f.inputStream(), 1 shl 16)).use { inp ->
                while (true) {
                    val key = try { inp.readUTF() } catch (e: java.io.EOFException) { break }
                    val n = inp.readInt()
                    val bytes = ByteArray(n * 4); inp.readFully(bytes)
                    val v = FloatArray(n); java.nio.ByteBuffer.wrap(bytes).asFloatBuffer().get(v)
                    cache[key] = v; count++
                }
            }
        }
        if (count > MAX_CACHE) { trim(); rewrite() }
    }

    private fun trim() { val it = cache.keys.iterator(); while (cache.size > MAX_CACHE && it.hasNext()) { it.next(); it.remove() } }

    private fun rewrite() {
        val f = binFile ?: return
        val tmp = File(f.path + ".tmp")
        java.io.DataOutputStream(java.io.BufferedOutputStream(tmp.outputStream(), 1 shl 16)).use { out -> for ((k, v) in cache) write(out, k, v) }
        tmp.renameTo(f)
    }

    private fun write(out: java.io.DataOutputStream, k: String, v: FloatArray) {
        out.writeUTF(k); out.writeInt(v.size)
        val b = java.nio.ByteBuffer.allocate(v.size * 4); b.asFloatBuffer().put(v); out.write(b.array())
    }

    companion object {
        // must stay well above the number of search docs (a few thousand), or vectors in use get evicted and re-fetched forever
        const val MAX_CACHE = 15000
        const val DEFAULT_RETRIEVAL_URL = "https://containers.datacrunch.io/muisti-retrieval"
        const val MODEL = "nemotron-3.5-embed"
    }

    fun available() = keyOf().isNotEmpty()

    private fun k(kind: String, text: String): String {
        val d = MessageDigest.getInstance("SHA-1").digest("$kind\n$text".toByteArray())
        return d.joinToString("") { "%02x".format(it) }
    }

    fun embed(texts: List<String>, kind: String): List<FloatArray>? {
        if (!available() || texts.isEmpty()) return null
        // the lock only guards the cache, never a network call: a question's embedding must not
        // wait behind a background pass over thousands of memories
        val missing = synchronized(lock) { ensureLoaded(); texts.distinct().filter { k(kind, it) !in cache } }
        try {
            for (batch in missing.chunked(32)) {
                val inputs = JSONArray()
                for (t in batch) inputs.put(JSONObject().put("content", JSONArray().put(JSONObject().put("type", "text").put("text", t))))
                val body = JSONObject().put("model", MODEL).put("input_type", if (kind == "query") "query" else "document")
                    .put("embedding_types", JSONArray().put("float")).put("truncate", "END").put("inputs", inputs)
                val req = Request.Builder().url(retrievalUrlOf().trimEnd('/') + "/v2/embed")
                    .header("Authorization", "Bearer ${keyOf()}")
                    .post(body.toString().toRequestBody("application/json".toMediaType())).build()
                val vecs = http.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) throw RuntimeException("embed HTTP ${resp.code}")
                    val data = JSONObject(resp.body!!.string()).getJSONObject("embeddings").getJSONArray("float")
                    batch.indices.map { i ->
                        val e = data.getJSONArray(i)
                        val v = FloatArray(e.length()) { e.getDouble(it).toFloat() }
                        var n = 0.0; for (x in v) n += x * x
                        val norm = maxOf(Math.sqrt(n), 1e-8).toFloat()
                        for (j in v.indices) v[j] /= norm
                        v
                    }
                }
                synchronized(lock) {
                    binFile?.let { f ->
                        java.io.DataOutputStream(java.io.FileOutputStream(f, true).buffered()).use { out ->
                            for ((t, v) in batch.zip(vecs)) { cache[k(kind, t)] = v; write(out, k(kind, t), v) }
                        }
                    } ?: batch.zip(vecs).forEach { (t, v) -> cache[k(kind, t)] = v }
                }
            }
        } catch (e: Exception) {
            if (missing.isNotEmpty()) return null
        }
        return synchronized(lock) { texts.map { cache[k(kind, it)] ?: return null } }
    }
}
