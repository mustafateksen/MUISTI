package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** One searchable memory document (ask.docs_from_sightings). seenAt is epoch milliseconds. */
class Doc(
    val type: String, val seenAt: Long, val frame: String?, val frameDir: String?, val source: String,
    val weak: Boolean, val name: String, val kind: String?, val subtype: String? = null,
    val phone: String? = null, val hours: String? = null, val text: String,
    val support: Int = 1, val uncertain: Boolean = false, val content: String? = null, val medium: String? = null,
) {
    var vec: FloatArray? = null
    var lat: Double? = null; var lon: Double? = null; var street: String? = null
}

class Evidence(val id: String, val text: String, val frame: String?, val seenAt: Long, val score: Double,
               val lat: Double? = null, val lon: Double? = null, val street: String? = null)

class Answer(val question: String, val label: String, val answer: String, val used: List<String>,
             val evidence: List<Evidence>, val why: String, val calls: Int, val latencyS: Double, val parsed: JSONObject)

/**
 * Port of ask.py (parse -> search -> gates -> answer -> verify -> look again), plus one
 * phone-only path: "what are you seeing right now?" answered from the live camera frame.
 */
class Asker(private val llm: Llm, private val prompts: Prompts, private val images: Images, private val embedder: Embedder?) {

    companion object {
        val ATTRIBUTES = listOf("location", "phone", "hours", "name", "description", "list", "when", "current_location", "other")
        val TIMES = listOf("just_now", "last_hour", "today", "any")

        fun docsFromSightings(sightings: List<JSONObject>): List<Doc> {
            val docs = ArrayList<Doc>()
            for (s in sightings) {
                val start = docs.size
                val seen = s.optLong("seen_at")
                val frame = s.str("evidence_frame"); val fdir = s.str("frame_dir"); val src = s.str("source") ?: ""
                val weak = s.bool("weak")
                val sname = s.str("name")
                val place = s.obj("scene").str("place_type") ?: ""
                val where = place + (if (sname != null) " near $sname" else "")
                val variants = s.arr("name_variants").strings().filter { it != sname }
                val objects = s.arr("objects").objects()
                val fields = listOfNotNull(
                    "Type: ${s.str("kind")} (${s.str("subtype")})",
                    sname?.let { "Name on sign: $it" },
                    variants.takeIf { it.isNotEmpty() }?.let { "Name also read as: ${it.joinToString(", ")}" },
                    s.str("phone")?.let { "Phone on sign: $it" },
                    s.str("hours")?.let { "Hours on sign: $it" },
                    s.str("other_text")?.let { "Other text on sign: $it" },
                    s.str("street")?.let { "Street: $it" },
                    s.str("caption")?.let { "Scene: $it" },
                    objects.takeIf { it.isNotEmpty() }?.let { "Visible things: " + it.take(12).joinToString(", ") { o -> o.str("name") ?: "" } })
                docs.add(Doc("sighting", seen, frame, fdir, src, weak, (listOf(sname ?: "") + variants).joinToString(" / "),
                    s.str("kind"), s.str("subtype"), s.str("phone"), s.str("hours"), fields.joinToString(". ")))
                for (it in s.arr("items").objects())
                    docs.add(Doc("item", seen, frame, fdir, src, weak, it.str("value") ?: "", "directory entry",
                        text = "${it.str("value")} -> ${it.str("label")} (on the ${sname ?: ""} ${s.str("subtype") ?: "sign"})"))
                val rels = s.arr("relations").objects().sortedBy { -it.optInt("support", 1) }
                for (o in objects) {
                    val on = o.str("name") ?: ""
                    val rs = rels.filter { on == it.str("subject") || on == it.str("object") }
                        .map { "${it.str("subject")} ${it.str("relation")} ${it.str("object")} (seen in ${it.optInt("support", 1)} frames)" }
                    val sup = o.optInt("support", 1)
                    docs.add(Doc("object", seen, o.str("frame") ?: frame, fdir, src, weak, on, o.str("category"),
                        text = "Seen object: $on (${o.str("category")}). How many at once: ${o.optInt("count", 1)}. Details: ${o.str("details")}. " +
                            "Where: ${o.str("position")} of view, ${o.str("distance")}, in a $where." +
                            (if (rs.isNotEmpty()) " Spatial: ${rs.joinToString("; ")}." else "") +
                            " (Noticed in $sup video frame(s); this is NOT a count of objects.)" +
                            (if (o.bool("uncertain")) " UNCERTAIN: the glasses were not sure they saw this." else ""),
                        support = sup, uncertain = o.bool("uncertain")))
                }
                for (dp in s.arr("depictions").objects()) {
                    val depicted = dp.arr("depicted").strings()
                    val hints = pictureHints(dp.str("content"), depicted)
                    docs.add(Doc("depiction", seen, dp.str("frame") ?: frame, fdir, src, weak,
                        "${dp.str("content") ?: ""} ${depicted.joinToString(" ")}$hints", "picture on ${dp.str("medium")}",
                        text = "PICTURE (not a real object): ${dp.str("content")}. Shown on: ${dp.str("on") ?: dp.str("medium")} " +
                            "(${dp.str("medium")}), in a $where. Things in the picture: ${depicted.joinToString(", ")}.$hints",
                        support = dp.optInt("support", 1), content = dp.str("content"), medium = dp.str("medium")))
                }
                if (s.has("lat") && !s.isNull("lat")) for (d in docs.subList(start, docs.size)) {
                    d.lat = s.getDouble("lat"); d.lon = s.getDouble("lon"); d.street = s.str("street")
                }
            }
            return docs
        }

        private val PEOPLE_WORDS = setOf("man", "woman", "men", "women", "person", "people", "child", "children", "boy", "girl", "team", "crowd", "worker")
        private val SCREEN_WORDS = setOf("laptop", "computer", "monitor", "phone", "tablet", "screen", "display")
        private fun pictureHints(content: String?, depicted: List<String>): String {
            val words = Regex("[a-z]+").findAll((content ?: "").lowercase() + " " + depicted.joinToString(" ").lowercase()).map { it.value }.toSet()
            val hints = ArrayList<String>()
            if (words.any { it in PEOPLE_WORDS }) hints.add("people")
            if (words.any { it in SCREEN_WORDS }) hints.add("computer screens")
            return if (hints.isNotEmpty()) " Also: ${hints.joinToString(", ")}." else ""
        }
    }

    // --- search (lexical + fuzzy + semantic) ----------------------------------------

    private val GENERIC = setOf("the", "booth", "stand", "sign", "banner", "poster", "screen", "stall", "of", "on", "at", "a", "an",
        "with", "in", "for", "and", "to", "from", "by", "near", "was", "were", "is", "did", "do", "i", "my",
        "which", "what", "where", "there", "it", "that", "this", "some", "any")

    private fun stem(t: String): String {
        for (suf in listOf("ing", "es", "s", "e"))
            if (t.endsWith(suf) && t.length - suf.length >= 3 && !t.endsWith("ss")) return t.dropLast(suf.length)
        return t
    }

    private val MEDIUM = listOf("picture", "pictures", "photo", "photos", "image", "images", "display", "displays",
        "electronic", "electronics", "screens", "tv", "monitor", "video").map { stem(it) }.toSet()
    private val TOKEN = Regex("[a-z0-9]+")

    private fun tokens(s: String?, dropGeneric: Boolean = false): List<String> {
        val toks = TOKEN.findAll((s ?: "").lowercase()).map { it.value }.filter { it.length > 1 }.map { stem(it) }.toList()
        if (!dropGeneric) return toks
        val kept = toks.filter { it !in GENERIC && it !in MEDIUM }
        return kept.ifEmpty { toks.filter { it !in GENERIC }.ifEmpty { toks } }
    }

    private val tokCache = HashMap<String, Set<String>>()
    private val simCache = HashMap<String, Double>()
    private fun docTokens(text: String) = tokCache.getOrPut(text) { tokens(text).toSet() }
    private fun tokSim(a: String, b: String) = simCache.getOrPut("$a\u0000$b") { Difflib.ratio(a, b) }

    fun tokMatch(q: String?, text: String?): Double {
        val qt = tokens(q, true); val tt = docTokens(text ?: "")
        if (qt.isEmpty() || tt.isEmpty()) return 0.0
        var hit = 0.0
        for (a in qt) {
            if (a in tt) { hit += 1; continue }
            val best = tt.filter { Math.abs(a.length - it.length) <= 3 }.maxOfOrNull { tokSim(a, it) } ?: 0.0
            val prefix = tt.any { b -> a.length >= 4 && b.length >= 4 && (a.startsWith(b) || b.startsWith(a)) }
            hit += if (best >= 0.85) 1.0 else if (best >= 0.7 || prefix) 0.5 else 0.0
        }
        return hit / qt.size
    }

    private val SEM_WEIGHT = 8.0
    private val SEM_FLOOR = 0.35
    private fun windowMin(time: String) = when (time) { "just_now" -> 20.0; "last_hour" -> 60.0; "today" -> 24 * 60.0; else -> 1e6 }
    private fun round3(x: Double) = Math.round(x * 1000) / 1000.0

    fun search(parsed: JSONObject, docs: List<Doc>, now: Long, k: Int = 5, qvec: FloatArray? = null): List<Pair<Double, Doc>> {
        val window = windowMin(parsed.optString("time", "any"))
        val target = parsed.str("target"); val category = parsed.str("category"); val attr = parsed.optString("attribute")
        val syns = parsed.arr("synonyms").strings().filter { t ->
            t.isNotEmpty() && tokens(t).any { x -> x !in GENERIC && x !in MEDIUM && x !in setOf("signag", "advertis", "advertisement") }
        }
        val terms = listOfNotNull(target?.let { it to 1.0 }) + syns.map { it to 0.7 }
        val asked = Regex("""\b(banner|poster|billboard|screen|sign|painting)s?\b""").findAll((target ?: "").lowercase()).map { it.groupValues[1] }.toList()
        val printed = setOf("banner", "poster", "billboard", "sign", "painting")
        val scored = ArrayList<Pair<Double, Doc>>()
        for (d in docs) {
            var s = 0.0
            if (terms.isNotEmpty()) s += terms.maxOf { (t, w) -> w * (2.0 * tokMatch(t, d.name) + 1.0 * tokMatch(t, d.text)) }
            if (category != null) s += 1.5 * tokMatch(category, "${d.kind} ${d.subtype} ${d.text}")
            val v = d.vec
            if (qvec != null && v != null) { var dot = 0.0; for (i in v.indices) dot += v[i] * qvec[i]; s += SEM_WEIGHT * maxOf(0.0, dot - SEM_FLOOR) }
            if (attr == "location" && d.type == "item") s += 0.3
            if (d.type == "depiction" && d.medium != null && asked.any { it == d.medium || (it in printed && d.medium in printed) }) s += 0.8
            if (d.type == "object" && d.support >= 2) s += 0.2
            if (attr in setOf("description", "name", "phone", "hours") && d.type == "sighting" &&
                Regex("Other text on sign|Phone on sign|Hours on sign").containsMatchIn(d.text)) s += 0.6
            if (d.weak) s *= 0.7
            if (d.uncertain) s *= 0.6
            if ((now - d.seenAt) / 60000.0 > window) s *= 0.5
            scored.add(round3(s) to d)
        }
        return scored.sortedBy { -it.first }.take(k).filter { it.first > 0 }   // sortedBy is stable, like Python
    }

    fun semanticSetup(question: String, docs: List<Doc>): FloatArray? {
        val e = embedder ?: return null
        if (!e.available()) return null
        val todo = docs.filter { it.vec == null }
        if (todo.isNotEmpty()) e.embed(todo.map { it.text }, "passage")?.let { vs -> todo.zip(vs).forEach { (d, v) -> d.vec = v } }
        return e.embed(listOf(question), "query")?.firstOrNull()
    }

    fun parseQuestion(q: String): JSONObject {
        val p = llm.jsonCall(prompts.parsePrompt, q, prompts.parseSchema, "query")
        if (p.optString("attribute") !in ATTRIBUTES) p.put("attribute", "other")
        if (p.optString("time") !in TIMES) p.put("time", "any")
        if (p.optString("intent") !in listOf("memory", "live", "summary", "forget", "chat")) p.put("intent", "memory")
        return p
    }

    internal fun ago(now: Long, t: Long): String {
        val m = ((now - t) / 60000).toInt()
        return if (m < 2) "just now" else if (m < 90) "$m minutes ago" else "at " + SimpleDateFormat("HH:mm", Locale.US).format(Date(t))
    }

    // --- summaries, names, live look -------------------------------------------------

    private val NAMEISH = setOf("brand", "brands", "logo", "logos", "company", "companies", "name", "names", "sign", "signs",
        "text", "store", "stores", "shop", "shops", "sponsor", "sponsors", "product", "products")
    private val FLOOR_INFO = Regex("""\b(\d{1,2}(st|nd|rd|th)\s*floor|floor\s*(label|number|indicator)|floor\s+\d+|level\s*\d+|[BL]\d{1,2}|\d+\.\s*kat)\b""", RegexOption.IGNORE_CASE)

    /** Period for summaries / name lists: the minutes the model read from the question, else its time range. */
    private fun summaryWindow(question: String, parsed: JSONObject): Double {
        if (parsed.num("minutes") > 0) return parsed.num("minutes")
        return when (parsed.optString("time")) { "just_now" -> 15.0; "last_hour" -> 60.0; "today" -> 24 * 60.0; else -> 1e6 }
    }

    internal fun namesSeen(docs: List<Doc>): List<Pair<String, Doc>> {
        fun ok(c: String): Boolean { val l = c.count { it.isLetter() }; return c.length >= 3 && l >= 3 && l.toDouble() / c.length >= 0.6 }
        fun key(c: String) = c.lowercase().replace(Regex("[^a-z0-9]"), "")
        val sights = docs.filter { it.type == "sighting" && !it.weak }.sortedBy { it.seenAt }
        val out = ArrayList<Pair<String, Doc>>(); val seen = HashSet<String>()
        for (d in sights) {
            val c = d.name.split(" / ")[0].trim(' ', '.', ',', ':', ';')
            if (ok(c) && seen.add(key(c))) out.add(c to d)
        }
        val counts = LinkedHashMap<String, Int>(); val first = HashMap<String, Pair<String, Doc>>()
        val other = Regex("""Other text on sign: (.*?)(?:\. [A-Z][a-z]+:|$)""")
        for (d in sights) {
            val m = other.find(d.text) ?: continue
            for (c0 in m.groupValues[1].split(" / ")) {
                val c = c0.trim(' ', '.', ',', ':', ';')
                if (ok(c) && key(c) !in seen) { counts[key(c)] = (counts[key(c)] ?: 0) + 1; first.putIfAbsent(key(c), c to d) }
            }
        }
        out += counts.filter { it.value >= 2 }.keys.map { first[it]!! }
        return out
    }

    internal fun liveLook(question: String, frame: ByteArray): String {
        val msgs = JSONArray().put(JSONObject().put("role", "user").put("content", JSONArray()
            .put(llm.imagePart(images.downscale(frame)))
            .put(llm.textPart("This photo is what the user's camera sees right now. Answer their question about it in one or two " +
                "short spoken sentences. If there is readable text that matters, read it exactly. Do not guess what you cannot see. " +
                "Question: $question"))))
        return llm.call(msgs, RawJson.TEXT, 300, 0.0).trim()
    }

    // --- main entry --------------------------------------------------------------------

    fun ask(question: String, docs: List<Doc>, now: Long, liveFrame: ByteArray? = null, minScore: Double = 0.9): Answer {
        val t0 = System.currentTimeMillis()
        var calls = 0
        var hits: List<Pair<Double, Doc>> = emptyList()
        var parsed = JSONObject()
        fun result(label: String, answer: String, used: List<String> = emptyList(), why: String = ""): Answer {
            val ev = hits.mapIndexed { i, (s, d) -> Evidence("E${i + 1}", d.text, d.frame, d.seenAt, s, d.lat, d.lon, d.street) }
            return Answer(question, label, answer, used, ev, why, calls, (System.currentTimeMillis() - t0) / 1000.0, parsed)
        }

        // One model call understands the request; routing follows its "intent" (no keyword rules).
        parsed = parseQuestion(question); calls++
        when (parsed.optString("intent")) {
            "live" -> if (liveFrame != null) {
                val a = liveLook(question, liveFrame); calls++
                return result("SEEN", a, why = "live look at the current camera frame")
            }
            "forget" -> return result("FORGET", "Okay, I forgot everything from the last ${(parsed.num("minutes").takeIf { it > 0 } ?: 10.0).toInt()} minutes.",
                why = "forget request")
            "chat" -> return result("ROUTE_CHAT", "", why = "small talk")
        }
        val target = parsed.str("target")
        val attr = parsed.optString("attribute")
        hits = if (attr == "current_location") {
            // "where am I now?" is about the LATEST memories, not about matching words
            val recent = docs.filter { it.seenAt <= now && now - it.seenAt <= 180_000 }
                .sortedWith(compareBy<Doc>({ it.seenAt }, { it.type != "object" })).reversed()
            val floorish = recent.filter { FLOOR_INFO.containsMatchIn(it.text) }
            (floorish.take(3) + recent.filter { it !in floorish.take(3) }).take(5).map { 1.0 to it }
        } else search(parsed, docs, now, qvec = semanticSetup(question, docs))

        if (parsed.optString("intent") == "summary") {
            val win = summaryWindow(question, parsed)
            val pool = docs.filter { it.type == "sighting" && it.seenAt <= now && (now - it.seenAt) / 60000.0 <= win }.sortedBy { it.seenAt }
            if (pool.isEmpty()) return result("DONT_KNOW", "I haven't seen anything in that time.", why = "summary: nothing in window")
            val step = maxOf(1, pool.size / 12)
            hits = pool.filterIndexed { i, _ -> i % step == 0 }.takeLast(12).map { 1.0 to it }
            val ev = hits.mapIndexed { i, (_, d) -> "E${i + 1} (${ago(now, d.seenAt)}): ${d.text}" }.joinToString("\n")
            val r = llm.jsonCall(prompts.summaryPrompt, ev, prompts.summarySchema, "summary"); calls++
            return result("SEEN", r.str("answer") ?: "I saw several places but can't summarise them.",
                r.arr("used").strings().filter { Regex("E\\d+").matches(it) }, "summary of last ${win.toInt()} min")
        }

        val gate = if (target != null) minScore else minOf(minScore, 0.5)
        if (hits.isEmpty() || (attr != "current_location" && hits[0].first < gate))
            return result("DONT_KNOW", "I don't remember seeing that.", why = "no relevant memory (gate)")

        if (attr == "phone" || attr == "hours") {
            val top = hits.filter { it.first >= minScore }.map { it.second }
            if (top.none { (if (attr == "phone") it.phone else it.hours) != null }) {
                val name = top.firstOrNull()?.name?.ifEmpty { null } ?: "it"
                return result("DONT_KNOW", "I saw $name, but I didn't see a ${if (attr == "hours") "opening hours" else "phone"} sign for it.",
                    why = "no $attr in matching memories (gate)")
            }
        }

        val category = parsed.str("category")
        if (attr == "list" && (category ?: "").lowercase() in NAMEISH) {
            val win = summaryWindow(question, parsed)
            val names = namesSeen(docs.filter { it.seenAt <= now && (now - it.seenAt) / 60000.0 <= win })
            if (names.isEmpty()) return result("DONT_KNOW", "I didn't read any names or brands.", why = "list: no OCR names")
            hits = names.take(5).map { 1.0 to it.second }
            val more = if (names.size > 10) " and ${names.size - 10} more" else ""
            return result("SEEN", "I read these names: ${names.take(10).joinToString(", ") { it.first }}$more.",
                hits.indices.map { "E${it + 1}" }, "list: names read on signs (code)")
        }

        if (attr == "list" && category != null) {
            val matches = docs.filter { it.type == "sighting" && !it.weak }
                .map { tokMatch(category, "${it.kind} ${it.subtype} ${it.name}") to it }.filter { it.first >= 0.5 }
            val pool = matches.filter { it.second.name.trim(' ', '/').isNotEmpty() }.sortedBy { it.second.seenAt }
            val names = ArrayList<String>()
            for ((_, d) in pool) {
                val n = d.name.split(" / ")[0].trim().ifEmpty { d.subtype ?: "" }
                if (n.isNotEmpty() && names.none { x -> x.lowercase().contains(n.lowercase()) || n.lowercase().contains(x.lowercase()) }) names.add(n)
            }
            if (names.isEmpty() && matches.isNotEmpty()) {
                val kinds = matches.map { (it.second.subtype ?: it.second.kind ?: "").trim() }.filter { it.isNotEmpty() }.toSortedSet().take(2)
                hits = matches.sortedBy { -it.first }.take(5)
                return result("UNSURE", "I was at a ${kinds.joinToString(" / ").ifEmpty { category }}, but I didn't read the name of any $category booth or place there.",
                    hits.indices.map { "E${it + 1}" }, "list: category matched only unnamed scenes")
            }
            if (names.isEmpty()) return result("DONT_KNOW", "I don't remember seeing any $category.", why = "list: no sighting matches category")
            hits = pool.take(5)
            val more = if (names.size > 6) " and ${names.size - 6} more" else ""
            return result("SEEN", "I saw ${names.size}: ${names.take(6).joinToString(", ")}$more.", hits.indices.map { "E${it + 1}" },
                "list answered from typed memories (code)")
        }

        val evBlock = hits.mapIndexed { i, (_, d) -> "E${i + 1} (seen ${ago(now, d.seenAt)}): ${d.text}" }.joinToString("\n")
        val out = llm.jsonCall(prompts.answerPrompt, "EVIDENCE:\n$evBlock\n\nQUESTION: $question", prompts.answerSchema, "answer"); calls++
        val usedIds = out.arr("evidence").strings()
        if (out.str("label") != "SEEN") return result("DONT_KNOW", out.str("answer") ?: "I don't remember seeing that.", why = "model abstained")
        if (out.str("support") != "stated" && out.str("observations") != null)
            return result("UNSURE", "I'm not sure. ${out.str("observations")}", usedIds, "answer was inferred, not stated in evidence")

        val eid = Regex("E\\d+")
        val usedDocs = usedIds.filter { eid.matches(it) && it.substring(1).toInt() in 1..hits.size }.map { hits[it.substring(1).toInt() - 1].second }
        val cited = usedDocs.map { it.text }
        val quotes = out.arr("quotes").strings().filter { it.isNotBlank() }
        val badQ = quotes.filter { q -> cited.none { Verify.fuzzyIn(q, it) } }
        if (cited.isEmpty() || quotes.isEmpty() || badQ.isNotEmpty())
            return result("DONT_KNOW", "I'm not sure. I can show you the closest thing I saw.", why = "verifier rejected quotes ${badQ.ifEmpty { quotes }}")
        val numsEv = Regex("\\d+").findAll(cited.joinToString(" ")).map { it.value }.toSet()
        val bad = Regex("\\d+").findAll(out.str("answer") ?: "").map { it.value }.filter { it !in numsEv }.toList()
        if (bad.isNotEmpty()) return result("DONT_KNOW", "I'm not sure about the exact number. I can show you the frame.", why = "verifier: numbers $bad not in evidence")

        // visual facts have no OCR to check against: look again at the stored frame
        val terms = (listOfNotNull(target) + parsed.arr("synonyms").strings()).filter { it.isNotEmpty() }
        val rel = { d: Doc -> terms.maxOfOrNull { tokMatch(it, d.name) } ?: 0.0 }
        val objDocs = usedDocs.filter { it.type == "object" || it.type == "depiction" }
            .sortedWith(compareBy<Doc>({ -rel(it) }, { -it.support }))
        val textBacked = usedDocs.any { it.type != "object" && it.type != "depiction" }
        val answer = out.str("answer") ?: ""
        if (objDocs.isNotEmpty() && !textBacked) {
            val notes = ArrayList<String>()
            for (d in objDocs.take(3)) {
                val (ok, note) = lookAgain(d); calls++
                notes.add("${d.name}@${d.frame}: ${if (ok) "yes" else "no"}")
                if (ok) {
                    mediumGuard(question, usedDocs)?.let { return result("DONT_KNOW", it, usedIds, "medium mismatch (code)") }
                    return result("SEEN", answer, usedIds, "verified ${quotes.size} quote(s) + visual re-check (${d.name}): $note")
                }
            }
            val d = objDocs[0]
            val what = if (d.type == "depiction") "a picture (${d.content}) on a ${d.medium}" else "a ${d.name}"
            return result("DONT_KNOW", "I noted $what earlier, but looking at the photos again I'm not sure. I can show you the frames.",
                why = "visual re-check failed on ${notes.size} frame(s): ${notes.joinToString("; ")}")
        }
        mediumGuard(question, usedDocs)?.let { return result("DONT_KNOW", it, usedIds, "medium mismatch (code)") }
        return result("SEEN", answer, usedIds, "verified ${quotes.size} quote(s)")
    }

    private val MEDIA = listOf("poster", "banner", "billboard", "screen", "sign", "painting")
    internal fun mediumGuard(question: String, used: List<Doc>): String? {
        val asked = MEDIA.filter { Regex("\\b${it}s?\\b", RegexOption.IGNORE_CASE).containsMatchIn(question) }
        val deps = used.filter { it.type == "depiction" }
        fun group(m: String) = if (m == "screen") "screen" else "printed"
        val askedGroups = asked.map { group(it) }.toSet()
        if (asked.isEmpty() || deps.isEmpty() || deps.any { group(it.medium ?: "") in askedGroups }) return null
        val d = deps[0]
        return "Not on a ${asked[0]}. I did see ${d.content} on a ${d.medium}."
    }

    private val PRINTED_NATURE = listOf("qr code", "barcode", "logo", "sign", "poster", "banner", "label", "sticker", "menu",
        "map", "flyer", "leaflet", "brochure", "price tag", "text", "signage", "notice", "board")
    private fun printedByNature(name: String): Boolean { val n = name.lowercase().trim(); return PRINTED_NATURE.any { n == it || n.endsWith(" $it") } }

    internal fun lookAgain(doc: Doc): Pair<Boolean, String> {
        val f = File(doc.frameDir ?: "", doc.frame ?: "")
        if (doc.frameDir == null || !f.exists()) return true to "frame not available, trusted memory"
        val txt = when {
            doc.type == "depiction" -> prompts.fill(prompts.lookPicture, "medium" to (doc.medium ?: "banner or screen"), "content" to doc.content)
            printedByNature(doc.name) -> prompts.fill(prompts.lookPrinted, "name" to doc.name)
            else -> prompts.fill(prompts.lookReal, "name" to doc.name)
        }
        val msgs = JSONArray().put(JSONObject().put("role", "user").put("content", JSONArray()
            .put(llm.imagePart(images.downscale(f.readBytes()))).put(llm.textPart(txt))))
        return try {
            val r = JsonText.parse(llm.call(msgs, llm.schemaFormat("look", prompts.lookSchema), 200, 0.0))
            r.bool("present") to (r.str("where") ?: "").take(160)
        } catch (e: Exception) {
            true to "re-check unavailable (${e.javaClass.simpleName})"
        }
    }
}
