package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/** Something MUISTI tells the user without being asked. [topic] dedupes repeats; [evidence] = frames it rests on. */
data class Notice(val id: String, val type: String, val topic: String, val title: String, val body: String,
                  val createdAt: Long, val relevance: Double, val evidence: List<String> = emptyList()) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("type", type).put("topic", topic).put("title", title).put("body", body)
        .put("created_at", createdAt).put("relevance", relevance).put("evidence", JSONArray(evidence))

    companion object {
        const val CALENDAR = "calendar"; const val ARRIVAL = "arrival"; const val CLOSING = "closing"; const val SAFETY = "safety"; const val PATTERN = "pattern"
        val TYPES = listOf(CALENDAR, ARRIVAL, CLOSING, SAFETY, PATTERN)
        val LABELS = mapOf(CALENDAR to "Before calendar events", ARRIVAL to "Notes at places", CLOSING to "Places closing soon / deadlines",
            SAFETY to "Safety alerts", PATTERN to "Habits and routines")
        fun fromJson(j: JSONObject) = Notice(j.getString("id"), j.getString("type"), j.getString("topic"), j.getString("title"),
            j.getString("body"), j.getLong("created_at"), j.optDouble("relevance", 1.0), j.arr("evidence").strings())
    }
}

/** How a notice reaches the user. */
enum class Delivery { ALERT, INBOX, DROP }   // ALERT = Android notification (+ TTS if the voice session is open)

/**
 * When MUISTI may speak up (iOS InterventionPolicy, simplified): mute per type, a relevance threshold, quiet hours
 * (inbox only), at most one alert per [minGapMs] (default 15 min; safety ignores the gap but not mutes), and the same
 * topic at most once per [topicPauseMs].
 */
class InterventionPolicy(val minGapMs: Long = 15 * 60_000L, val quietStart: Int = 22, val quietEnd: Int = 7,
                         val minRelevance: Double = 0.5, val topicPauseMs: Long = 6 * 3600_000L, val muted: Set<String> = emptySet()) {
    fun quiet(now: Long): Boolean {
        if (quietStart == quietEnd) return false
        val h = Calendar.getInstance().apply { timeInMillis = now }.get(Calendar.HOUR_OF_DAY)
        return if (quietStart < quietEnd) h in quietStart until quietEnd else h >= quietStart || h < quietEnd
    }

    /** [history] = notices already decided (with their delivery), newest last. */
    fun decide(n: Notice, now: Long, history: List<Pair<Notice, Delivery>>): Delivery {
        if (n.type in muted || n.relevance < minRelevance) return Delivery.DROP
        if (history.any { (h, d) -> d != Delivery.DROP && h.topic == n.topic && now - h.createdAt < topicPauseMs }) return Delivery.DROP
        if (quiet(now) && n.type != Notice.SAFETY) return Delivery.INBOX
        if (n.type == Notice.SAFETY) return Delivery.ALERT
        val lastAlert = history.filter { it.second == Delivery.ALERT && it.first.type != Notice.SAFETY }.maxOfOrNull { it.first.createdAt }
        return if (lastAlert != null && now - lastAlert < minGapMs) Delivery.INBOX else Delivery.ALERT
    }
}

/** A calendar event (from the phone's calendar). */
data class CalEvent(val id: Long, val title: String, val start: Long, val location: String?)

/** Notice sources: small, pure, each tested with fixed inputs. */
object NoticeSources {
    private val TOKEN = Regex("[\\p{L}0-9]{3,}")
    private val STOP = setOf("the", "and", "with", "for", "meeting", "event", "call", "from", "this", "that")
    private fun toks(s: String?) = TOKEN.findAll((s ?: "").lowercase()).map { it.value }.filter { it !in STOP }.toSet()

    /** An event starting within 30 min, and memories that mention it (title / place words): "you saw its poster at 09:08". */
    fun calendar(events: List<CalEvent>, docs: List<Doc>, now: Long, ago: (Long) -> String): List<Notice> = events
        .filter { it.start in now..(now + 30 * 60_000L) }
        .mapNotNull { e ->
            val words = toks(e.title) + toks(e.location)
            if (words.isEmpty()) return@mapNotNull null
            val related = docs.filter { d -> d.type == "sighting" || d.type == "note" }
                .map { d -> d to (toks(d.text) intersect words).size.toDouble() / words.size }.filter { it.second >= 0.5 }
                .sortedByDescending { it.second }.take(3)
            if (related.isEmpty()) return@mapNotNull null
            val mins = ((e.start - now) / 60_000).toInt()
            val first = related[0].first
            Notice("cal-${e.id}-${e.start}", Notice.CALENDAR, "cal:${e.id}", "In $mins min: ${e.title}",
                "Related memory from ${ago(first.seenAt)}: ${first.text.take(160)}", now, related[0].second,
                related.mapNotNull { it.first.frame })
        }

    /** Arriving (within [radiusM]) where the user noted something earlier (at least an hour ago). */
    fun arrival(lat: Double, lon: Double, notes: List<Note>, now: Long, radiusM: Double = 150.0): List<Notice> = notes
        .filter { it.lat != null && it.lon != null && now - it.createdAt > 3600_000L }
        .filter { dist(lat, lon, it.lat!!, it.lon!!) <= radiusM }
        .map { n -> Notice("arr-${n.id}-${now / 3600_000L}", Notice.ARRIVAL, "note:${n.id}", "You noted something here",
            n.text, now, 1.0, listOfNotNull(n.frame)) }

    /** Signs read today whose opening hours end within 45 min, and "by <weekday>" deadlines falling today. */
    fun closingSoon(sightings: List<Doc>, now: Long): List<Notice> {
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        val dow = cal.get(Calendar.DAY_OF_WEEK)
        val minuteOfDay = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        val today0 = now - minuteOfDay * 60_000L - cal.get(Calendar.SECOND) * 1000L
        val out = ArrayList<Notice>()
        for (d in sightings.filter { it.type == "sighting" && it.seenAt >= today0 - 24 * 3600_000L }) {
            val name = d.name.split(" / ")[0].ifEmpty { "A place" }
            d.hours?.let { h -> Hours.closing(h, dow)?.let { close ->
                val left = close * 60 - minuteOfDay
                if (left in 1..45) out.add(Notice("close-${name.hashCode()}-${today0}", Notice.CLOSING, "close:${name.lowercase()}",
                    "$name closes in $left min", "Hours on the sign: $h", now, 0.8, listOfNotNull(d.frame)))
            } }
            Regex("""\bby (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b""", RegexOption.IGNORE_CASE).find(d.text)?.let { m ->
                if (Hours.dayIndex(m.groupValues[1]) == dow) {
                    val line = d.text.substringAfter("Other text on sign: ", d.text).substringBefore(". ").take(120)
                    out.add(Notice("due-${d.text.hashCode()}-${today0}", Notice.CLOSING, "due:${line.lowercase().take(40)}",
                        "Due today", line, now, 0.9, listOfNotNull(d.frame)))
                }
            }
        }
        return out.distinctBy { it.topic }
    }

    private fun dist(aLat: Double, aLon: Double, bLat: Double, bLon: Double): Double {
        val r = 6_371_000.0; val dLat = Math.toRadians(bLat - aLat); val dLon = Math.toRadians(bLon - aLon)
        val h = Math.sin(dLat / 2).let { it * it } + Math.cos(Math.toRadians(aLat)) * Math.cos(Math.toRadians(bLat)) * Math.sin(dLon / 2).let { it * it }
        return 2 * r * Math.asin(Math.sqrt(h))
    }
}

/** Opening hours as written on Finnish / English signs: "Ma-Pe 8-20, La 9-18", "Mon-Fri 8-16", "Daily 7-23". */
object Hours {
    private val DAYS = listOf(
        listOf("su", "sun", "sunday", "sunnuntai"), listOf("ma", "mon", "monday", "maanantai"), listOf("ti", "tue", "tuesday", "tiistai"),
        listOf("ke", "wed", "wednesday", "keskiviikko"), listOf("to", "thu", "thursday", "torstai"), listOf("pe", "fri", "friday", "perjantai"),
        listOf("la", "sat", "saturday", "lauantai"))

    /** Calendar.DAY_OF_WEEK (1 = Sunday) for a day word, or null. */
    fun dayIndex(w: String): Int? = DAYS.indexOfFirst { w.lowercase().trimEnd('.') in it }.takeIf { it >= 0 }?.plus(1)

    /** Closing hour (0-24) on [dow], or null if the sign does not say. */
    fun closing(text: String, dow: Int): Int? {
        val t = text.lowercase()
        for (part in t.split(Regex("[,;/]"))) {
            val m = Regex("""^\s*([\p{L}.]+)(?:\s*[-–]\s*([\p{L}.]+))?\s+(\d{1,2})(?:[:.]\d{2})?\s*[-–]\s*(\d{1,2})(?:[:.]\d{2})?""").find(part) ?: continue
            val (d1, d2, _, close) = m.destructured
            val days: Set<Int> = when {
                d1 in setOf("daily", "joka", "päivittäin", "every") -> (1..7).toSet()
                else -> {
                    val a = dayIndex(d1) ?: continue
                    val b = if (d2.isEmpty()) a else dayIndex(d2) ?: continue
                    // ranges wrap Monday -> Sunday in sign order (ma=2 .. su=1)
                    val order = listOf(2, 3, 4, 5, 6, 7, 1)
                    val i = order.indexOf(a); val j = order.indexOf(b)
                    if (i <= j) order.subList(i, j + 1).toSet() else (order.subList(i, 7) + order.subList(0, j + 1)).toSet()
                }
            }
            if (dow in days) return close.toInt().takeIf { it in 1..24 }
        }
        return null
    }
}

/** The notices inbox (notices.jsonl, with each one's delivery), newest last. */
class NoticeStore(dir: File) {
    private val file = File(dir, "notices.jsonl")
    private val lock = Any()

    fun all(): List<Pair<Notice, Delivery>> = synchronized(lock) {
        if (!file.exists()) return emptyList()
        file.readLines().mapNotNull { l -> runCatching { JSONObject(l).let { Notice.fromJson(it) to Delivery.valueOf(it.getString("delivery")) } }.getOrNull() }
    }

    fun add(n: Notice, d: Delivery) = synchronized(lock) { file.appendText(n.toJson().put("delivery", d.name).toString() + "\n") }

    /** Runs [candidates] through [policy]; stores everything not dropped. Returns what to alert now. */
    fun offer(candidates: List<Notice>, policy: InterventionPolicy, now: Long): List<Notice> = synchronized(lock) {
        val hist = all().toMutableList()
        val alerts = ArrayList<Notice>()
        for (n in candidates) {
            if (hist.any { it.first.id == n.id }) continue
            val d = policy.decide(n, now, hist)
            if (d != Delivery.DROP) { add(n, d); hist.add(n to d) }
            if (d == Delivery.ALERT) alerts.add(n)
        }
        alerts
    }
}
