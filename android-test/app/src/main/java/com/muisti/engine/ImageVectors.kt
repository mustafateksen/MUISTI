package com.muisti.engine

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File

/**
 * The MobileCLIP-S0 image vector of every kept frame (computed on the phone by the privacy gate anyway: no extra
 * model, no network). Binary file of [id int][dim int][dim floats] records; unit vectors, similarity = dot product.
 * Never mixed with other models' vectors (Nemotron text embeddings live in Embedder's cache).
 */
class ImageVectors(private val file: File) {
    private val lock = Any()
    private var map: LinkedHashMap<Int, FloatArray>? = null

    private fun load(): LinkedHashMap<Int, FloatArray> = map ?: LinkedHashMap<Int, FloatArray>().also { m ->
        if (file.exists()) runCatching {
            DataInputStream(file.inputStream().buffered(1 shl 16)).use { inp ->
                while (true) {
                    val id = try { inp.readInt() } catch (e: java.io.EOFException) { break }
                    val n = inp.readInt(); val v = FloatArray(n) { inp.readFloat() }
                    m[id] = v
                }
            }
        }
        map = m
    }

    fun put(id: Int, v: FloatArray) = synchronized(lock) {
        val u = unit(v)
        load()[id] = u
        DataOutputStream(java.io.FileOutputStream(file, true).buffered()).use { o -> o.writeInt(id); o.writeInt(u.size); u.forEach { o.writeFloat(it) } }
    }

    fun get(id: Int): FloatArray? = synchronized(lock) { load()[id] }
    fun size() = synchronized(lock) { load().size }

    fun delete(ids: Set<Int>) = synchronized(lock) {
        val m = load()
        if (ids.none { it in m }) return@synchronized
        ids.forEach { m.remove(it) }
        val tmp = File(file.path + ".tmp")
        DataOutputStream(tmp.outputStream().buffered()).use { o -> for ((id, v) in m) { o.writeInt(id); o.writeInt(v.size); v.forEach { o.writeFloat(it) } } }
        file.delete(); tmp.renameTo(file)
    }

    /** Top [k] frame ids by cosine with [q] (unit vector), best first. */
    fun search(q: FloatArray, k: Int = 5): List<Pair<Int, Double>> = synchronized(lock) {
        val u = unit(q)
        load().map { (id, v) -> id to dot(u, v) }.sortedByDescending { it.second }.take(k)
    }

    companion object {
        fun dot(a: FloatArray, b: FloatArray): Double { var s = 0.0; for (i in 0 until minOf(a.size, b.size)) s += a[i] * b[i]; return s }
        fun unit(v: FloatArray): FloatArray { var n = 0.0; for (x in v) n += x * x; val d = Math.sqrt(n).toFloat().coerceAtLeast(1e-8f); return FloatArray(v.size) { v[it] / d } }
    }
}

/**
 * `search_visual`: "where did I see a red sofa / a basketball hoop / a QR code". The search text is embedded on the
 * phone (MobileCLIP text encoder) and compared with the stored image vectors; the memories of the best frames are
 * returned as evidence. Floor 0.20 / within 0.05 of the best: measured on a CC test set (hits median 0.27,
 * non-hits median 0.12, p99 0.21).
 */
fun visualSearchTool(embedText: (String) -> FloatArray?, vectors: () -> ImageVectors, docFor: (frame: String) -> Doc?): ExtraTool =
    ExtraTool("search_visual",
        ExtraTool.function("search_visual", "Find frames by what they LOOK like (objects, colours, scenes) when words on signs do not help: 'a red sofa', 'a basketball hoop', 'a QR code'.",
            """{"type": "object", "properties": {"looks_like": {"type": "string", "description": "short English description of the thing to see, e.g. 'a red sofa'"}}, "required": ["looks_like"]}"""),
        "- search_visual: find a frame by its look (object, colour, scene) when search_memory finds nothing or the thing has no text.") { a, ctx ->
        val what = a.str("looks_like")?.trim().orEmpty()
        val q = if (what.isEmpty()) null else embedText("a photo of " + what.removePrefix("a photo of ").trim())
        if (q == null) ToolOut.Text("Visual search is not available right now.")
        else {
            val hits = vectors().search(q, 8)
            val best = hits.firstOrNull()?.second ?: 0.0
            val keep = hits.filter { it.second >= 0.20 && it.second >= best - 0.05 }.take(3)
            // an "object" doc named after the searched thing: if the answer rests on it, the verifier looks at the
            // stored frame again (through the privacy gate) before saying SEEN
            val lines = keep.mapNotNull { (id, sim) -> docFor("$id.jpg")?.let { d ->
                val v = Doc("object", d.seenAt, "$id.jpg", d.frameDir, d.source, false, what, "picture search",
                    text = "Seen object (found by picture search, similarity %.2f): %s. Memory of that moment: %s".format(sim, what, d.text))
                    .apply { lat = d.lat; lon = d.lon; street = d.street }
                ctx.ev(v)
            } }
            ToolOut.Text(if (lines.isEmpty()) "No stored picture looks like '$what'." else lines.joinToString("\n"))
        }
    }
