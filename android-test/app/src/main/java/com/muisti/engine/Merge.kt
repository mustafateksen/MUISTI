package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject

/** A stored frame: time in seconds, file name, verified record, optional 64-bit dHash. */
class Frame(val t: Double, val file: String, val record: JSONObject, val dhash: Long? = null)

/** Port of merge.py: consecutive records of the same sign/spot become one sighting. */
object Merge {
    private val WORD = Regex("[A-Z0-9]{3,}")
    val GENERIC_OBJECTS = setOf("screen", "door", "table", "chair", "light", "plant", "poster", "banner", "ceiling", "floor",
        "wall", "window", "sign", "truss", "curtain", "booth", "ceiling light", "lighting truss",
        "doorway", "pillar", "box", "backpack", "lanyard", "bottle", "laptop")

    private fun sim(a: String, b: String) = Difflib.ratio(a, b)

    private fun words(rec: JSONObject): Set<String> {
        val ol = rec.obj("ocr_lines")
        val text = ol.keys().asSequence().joinToString(" ") { ol.optString(it) } + " " + (rec.str("name") ?: "")
        return WORD.findAll(text.uppercase()).map { it.value }.toSet()
    }

    private fun namesConflict(name: String?, group: List<Frame>): Boolean {
        val names = group.mapNotNull { it.record.str("name")?.lowercase() }.toSet()
        if (name.isNullOrEmpty() || names.isEmpty()) return false
        val n = name.lowercase()
        return names.none { m -> n.contains(m) || m.contains(n) || sim(n, m) >= 0.6 }
    }

    private fun objNames(r: JSONObject) = r.arr("objects").objects().mapNotNull { it.str("name") }.toSet() - GENERIC_OBJECTS

    private fun sameSign(fa: Frame, fb: Frame): Boolean {
        val a = fa.record; val b = fb.record
        val na = (a.str("name") ?: "").lowercase(); val nb = (b.str("name") ?: "").lowercase()
        if (na.isNotEmpty() && nb.isNotEmpty() && (nb.contains(na) || na.contains(nb) || sim(na, nb) >= 0.6)) return true
        val wa = words(a); val wb = words(b)
        if (wa.isNotEmpty() && wb.isNotEmpty() && (wa intersect wb).size.toDouble() / (wa union wb).size >= 0.3) return true
        val ha = fa.dhash; val hb = fb.dhash
        if (ha != null && hb != null && Math.abs(fa.t - fb.t) <= 1.5 && java.lang.Long.bitCount(ha xor hb) <= 20) return true
        val oa = objNames(a); val ob = objNames(b)
        val pa = a.obj("scene").str("place_type"); val pb = b.obj("scene").str("place_type")
        return Math.abs(fa.t - fb.t) <= 2.5 && pa == pb && oa.size >= 2 && ob.size >= 2 &&
            (oa intersect ob).size.toDouble() / (oa union ob).size >= 0.5
    }

    private fun score(rec: JSONObject): Double {
        val filled = listOf("name", "phone", "hours", "other_text").count { rec.str(it) != null }
        return filled * 2 + rec.arr("items").length() * 1.5 + rec.num("confidence") +
            rec.arr("objects").length() * 0.2 - rec.arr("rejected").length() * 0.5
    }

    /** Python max(): first element with the highest key wins ties. */
    private fun <T> maxFirst(xs: List<T>, key: (T) -> Double): T {
        var best = xs[0]; var bk = key(best)
        for (x in xs.drop(1)) { val k = key(x); if (k > bk) { best = x; bk = k } }
        return best
    }

    private fun mergeObjects(group: List<Frame>): Pair<JSONArray, JSONArray> {
        val objs = LinkedHashMap<String, JSONObject>()
        for (fr in group) for (o in fr.record.arr("objects").objects()) {
            val name = o.str("name") ?: continue
            val cur = objs[name]
            if (cur == null) {
                objs[name] = o.copy().put("support", 1).put("frame", fr.file).put("count", o.num("count", 1.0).toInt())
            } else {
                cur.put("support", cur.optInt("support") + 1)
                cur.put("uncertain", cur.bool("uncertain") && o.bool("uncertain"))
                cur.put("count", maxOf(cur.num("count", 1.0), o.num("count", 1.0)).toInt())
                if ((o.str("details") ?: "").length > (cur.str("details") ?: "").length)
                    cur.put("details", o.opt("details")).put("position", o.opt("position")).put("distance", o.opt("distance")).put("frame", fr.file)
            }
        }
        val rels = LinkedHashMap<String, JSONObject>()
        for (fr in group) for (r in fr.record.arr("relations").objects()) {
            val key = "${r.str("subject")}\u0000${r.str("relation")}\u0000${r.str("object")}"
            val cur = rels[key]
            if (cur != null) cur.put("support", cur.optInt("support") + 1)
            else rels[key] = r.copy().put("support", 1).put("frame", fr.file)
        }
        // Python sorted() is stable: equal support keeps first-seen order
        return JSONArray(objs.values.sortedBy { -it.optInt("support") }) to JSONArray(rels.values.sortedBy { -it.optInt("support") })
    }

    private fun voteItems(recs: List<JSONObject>, bestRec: JSONObject, sameValue: Double = 0.6): JSONArray {
        val bestKeys = bestRec.arr("items").objects().map { (it.str("label") ?: "").uppercase() to (it.str("value") ?: "").uppercase() }.toSet()
        val votes = LinkedHashMap<Pair<String, String>, Int>()
        val framesOf = HashMap<Pair<String, String>, MutableSet<Int>>()
        for ((ri, r) in recs.withIndex()) for (it in r.arr("items").objects()) {
            val lab = (it.str("label") ?: "").uppercase().trim(); val v = (it.str("value") ?: "").uppercase().trim()
            if (sim(lab, v) > 0.8) continue                                  // '5TH FLOOR -> 5TH FLOOR' is not a fact
            if (!Regex("[A-Z]{2}").containsMatchIn(v)) continue             // '2 -> 11': OCR noise
            val k = lab to v
            votes[k] = (votes[k] ?: 0) + 1
            framesOf.getOrPut(k) { HashSet() }.add(ri)
        }
        // two rows read in the SAME frame are different rows, however similar: never cluster them
        val clusters = ArrayList<MutableList<Pair<String, String>>>()
        for (key in votes.keys) {
            var placed = false
            for (cl in clusters) {
                if (cl.any { (framesOf[key]!! intersect framesOf[it]!!).isNotEmpty() }) continue
                if (cl.any { sim(key.second, it.second) >= sameValue }) { cl.add(key); placed = true; break }
            }
            if (!placed) clusters.add(mutableListOf(key))
        }
        val out = JSONArray()
        for (cl in clusters) {
            val winner = maxFirst(cl) { votes[it]!! * 2.0 + (if (it in bestKeys) 1 else 0) }
            out.put(JSONObject().put("label", winner.first).put("value", winner.second).put("votes", votes[winner])
                .put("alternatives", JSONArray(cl.filter { it != winner }.map { "${it.first} -> ${it.second}" })))
        }
        return out
    }

    private fun mergeDepictions(group: List<Frame>): JSONArray {
        val out = ArrayList<JSONObject>()
        for (fr in group) for (d in fr.record.arr("depictions").objects()) {
            val match = out.firstOrNull { o ->
                o.str("medium") == d.str("medium") &&
                    sim((o.str("content") ?: "").lowercase(), (d.str("content") ?: "").lowercase()) >= 0.55
            }
            if (match != null) {
                match.put("support", match.optInt("support") + 1)
                match.put("depicted", JSONArray((match.arr("depicted").strings() + d.arr("depicted").strings()).toSortedSet().toList()))
            } else out.add(d.copy().put("support", 1).put("frame", fr.file))
        }
        return JSONArray(out.sortedBy { -it.optInt("support") })
    }

    fun mergeSightings(frames: List<Frame>, maxGapS: Double = 6.0): List<JSONObject> {
        val groups = ArrayList<MutableList<Frame>>()
        for (fr in frames) {
            if (!fr.record.bool("useful")) continue
            val g = groups.lastOrNull()
            if (g != null && fr.t - g.last().t <= maxGapS && !namesConflict(fr.record.str("name"), g) &&
                g.takeLast(3).any { sameSign(fr, it) }) g.add(fr)
            else groups.add(mutableListOf(fr))
        }
        val sightings = ArrayList<JSONObject>()
        for (g in groups) {
            val recs = g.map { it.record }
            val bestRec = maxFirst(recs) { score(it) }
            val best = bestRec.copy()
            // majority vote on the verified name; ties go to the best-evidenced frame
            val names = LinkedHashMap<String, Int>()
            for (r in recs) r.str("name")?.let { names[it] = (names[it] ?: 0) + 1 }
            if (names.isNotEmpty()) {
                val bn = bestRec.str("name")
                val conf = bestRec.num("confidence")
                best.put("name", maxFirst(names.keys.toList()) { n -> names[n]!! * 1000.0 + (if (n == bn) 100.0 + conf else 0.0) })
            }
            best.put("name_variants", JSONArray(names.keys.sorted()))
            for (f in listOf("phone", "hours", "other_text", "subtype"))
                if (best.str(f) == null) best.put(f, nullable(recs.firstNotNullOfOrNull { it.str(f) }))
            best.put("items", voteItems(recs, bestRec))
            best.put("t", g.first().t)
            best.put("t_end", g.last().t)
            best.put("frames", JSONArray(g.map { it.file }))
            best.put("evidence_frame", g[recs.indexOf(bestRec)].file)
            best.put("rejected", JSONArray(recs.flatMap { it.arr("rejected").objects() }))
            val (o, r) = mergeObjects(g)
            best.put("objects", o).put("relations", r)
            best.put("depictions", mergeDepictions(g))
            val name = best.str("name") ?: ""
            best.put("weak", name.isNotEmpty() && g.size == 1 && (name.length <= 4 || best.num("confidence") < 0.7))
            sightings.add(best)
        }
        return sightings
    }
}
