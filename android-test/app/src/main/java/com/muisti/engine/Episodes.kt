package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A stretch of the day: sightings close in time and place. Members are sighting keys (their evidence frame, e.g.
 * "123.jpg": stable, unlike the merge's running numbers). Every sighting belongs to exactly one episode.
 */
data class Episode(val id: String, val start: Long, val end: Long, val place: String?, val lat: Double?, val lon: Double?,
                   val keyFrames: List<String>, val members: List<String>, val sceneTypes: List<String>, val names: List<String>) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("start", start).put("end", end).put("place", nullable(place))
        .put("lat", nullable(lat)).put("lon", nullable(lon)).put("key_frames", JSONArray(keyFrames)).put("members", JSONArray(members))
        .put("scenes", JSONArray(sceneTypes)).put("names", JSONArray(names))

    companion object {
        fun fromJson(j: JSONObject) = Episode(j.getString("id"), j.getLong("start"), j.getLong("end"), j.str("place"),
            if (j.isNull("lat")) null else j.optDouble("lat"), if (j.isNull("lon")) null else j.optDouble("lon"),
            j.arr("key_frames").strings(), j.arr("members").strings(), j.arr("scenes").strings(), j.arr("names").strings())
    }
}

object Episodes {
    const val MAX_GAP_MS = 10 * 60_000L
    const val MAX_MOVE_M = 300.0
    const val SCENE_GAP_MS = 5 * 60_000L
    /** An episode is closed (summarisable) once nothing joined it for this long. */
    const val SETTLE_MS = MAX_GAP_MS

    fun key(s: JSONObject): String = s.str("evidence_frame") ?: "t${s.optLong("seen_at")}"

    private fun dist(aLat: Double, aLon: Double, bLat: Double, bLon: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(bLat - aLat); val dLon = Math.toRadians(bLon - aLon)
        val h = Math.sin(dLat / 2).let { it * it } + Math.cos(Math.toRadians(aLat)) * Math.cos(Math.toRadians(bLat)) * Math.sin(dLon / 2).let { it * it }
        return 2 * r * Math.asin(Math.sqrt(h))
    }

    /** Groups sightings (any order) into episodes, oldest first. Deterministic: same input, same episodes. */
    fun group(sightings: List<JSONObject>): List<Episode> {
        val sorted = sightings.sortedWith(compareBy({ it.optLong("seen_at") }, { key(it) }))
        val groups = ArrayList<MutableList<JSONObject>>()
        var lastLat: Double? = null; var lastLon: Double? = null
        for (s in sorted) {
            val g = groups.lastOrNull()
            val t = s.optLong("seen_at")
            val lat = if (s.has("lat") && !s.isNull("lat")) s.getDouble("lat") else null
            val lon = if (s.has("lon") && !s.isNull("lon")) s.getDouble("lon") else null
            val split = when {
                g == null -> true
                t - g.last().optLong("seen_at") > MAX_GAP_MS -> true
                lat != null && lastLat != null && dist(lastLat, lastLon!!, lat, lon!!) > MAX_MOVE_M -> true
                // no location on either side: a different kind of place after a pause is a new episode
                lat == null && lastLat == null && t - g.last().optLong("seen_at") >= SCENE_GAP_MS &&
                    scene(s) != null && scene(g.last()) != null && scene(s) != scene(g.last()) -> true
                else -> false
            }
            if (split) { groups.add(mutableListOf(s)); lastLat = lat; lastLon = lon } else { g!!.add(s); if (lat != null) { lastLat = lat; lastLon = lon } }
        }
        return groups.map { build(it) }
    }

    private fun scene(s: JSONObject) = s.obj("scene").str("place_type")

    private fun build(g: List<JSONObject>): Episode {
        val start = g.first().optLong("seen_at"); val end = g.last().optLong("seen_at")
        val streets = g.mapNotNull { it.str("street") }
        val place = streets.groupingBy { it }.eachCount().maxWithOrNull(compareBy({ it.value }, { -streets.indexOf(it.key) }))?.key
        val fix = g.firstOrNull { it.has("lat") && !it.isNull("lat") }
        // key frames: the most informative sightings (named, with text), spread over the episode, in time order
        fun info(s: JSONObject) = (if (s.str("name") != null) 3 else 0) + (if (s.str("other_text") != null) 2 else 0) +
            (if (s.str("phone") != null || s.str("hours") != null) 2 else 0) + minOf(3, s.arr("objects").length())
        val keys = g.withIndex().sortedWith(compareBy({ -info(it.value) }, { it.index })).take(4).sortedBy { it.index }.map { key(it.value) }
        return Episode("ep-$start-${key(g.first()).substringBefore('.')}", start, end, place,
            fix?.getDouble("lat"), fix?.getDouble("lon"), keys, g.map { key(it) },
            g.mapNotNull { scene(it) }.distinct(), g.mapNotNull { it.str("name") }.distinct())
    }

    /** One line per episode for the agent / UI headline. */
    fun headline(e: Episode, summary: String? = null): String {
        val f = SimpleDateFormat("HH:mm", Locale.US)
        val span = if (e.end - e.start < 60_000) f.format(Date(e.start)) else "${f.format(Date(e.start))}-${f.format(Date(e.end))}"
        val what = summary ?: listOfNotNull(e.sceneTypes.take(3).joinToString(", ").ifEmpty { null },
            e.names.take(4).joinToString(", ").ifEmpty { null }?.let { "signs: $it" }).joinToString("; ")
        return "Episode $span${e.place?.let { " on $it" } ?: ""} (${e.members.size} memories): $what"
    }

    /** Episodes as search documents (type "episode"): found by search_memory and listed by recent. */
    fun docs(eps: List<Episode>, summaries: Map<String, String>): List<Doc> = eps.map { e ->
        Doc("episode", e.start, e.keyFrames.firstOrNull(), null, "episode", false, e.names.take(3).joinToString(" / "), "episode",
            text = headline(e, summaries[e.id])).apply { lat = e.lat; lon = e.lon; street = e.place }
    }
}

/** episodes.json next to the memory: recomputed when the sightings change, read by the UI and the summariser. */
class EpisodeStore(dir: File) {
    private val file = File(dir, "episodes.json")
    @Volatile private var cache: List<Episode>? = null
    private var forSightings: List<JSONObject>? = null

    @Synchronized
    fun update(sightings: List<JSONObject>): List<Episode> {
        if (sightings === forSightings) cache?.let { return it }
        val eps = Episodes.group(sightings)
        runCatching { file.writeText(JSONArray(eps.map { it.toJson() }).toString()) }
        cache = eps; forSightings = sightings
        return eps
    }

    fun load(): List<Episode> = cache ?: runCatching {
        val a = JSONArray(file.readText()); (0 until a.length()).map { Episode.fromJson(a.getJSONObject(it)) }
    }.getOrDefault(emptyList())
}
