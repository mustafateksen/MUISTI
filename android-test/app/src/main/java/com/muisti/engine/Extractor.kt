package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject

/**
 * Port of extract.py: frame + OCR lines -> verified memory record.
 * The evidence rule lives in code: every text field must be supported by the OCR line it cites.
 */
class Extractor(private val llm: Llm, private val prompts: Prompts, private val images: Images) {

    var temperature = 0.2
    var maxTokens = 2500
    var detailRules = true
    var uncertainRules = true

    fun extract(jpeg: ByteArray, ocrLines: List<String>): JSONObject {
        val lines = Verify.numberLines(ocrLines)
        val ocrBlock = "OCR_LINES:\n" + (lines.entries.joinToString("\n") { "${it.key} ${it.value}" }.ifEmpty { "(none)" })
        val messages = JSONArray()
            .put(JSONObject().put("role", "system").put("content", prompts.extractionSystem))
            .put(JSONObject().put("role", "user").put("content", JSONArray()
                .put(llm.textPart(ocrBlock))                          // OCR before the image helps text-VQA
                .put(llm.imagePart(images.downscale(jpeg)))))
        var content = try {
            llm.call(messages, llm.schemaFormat("memory", prompts.recordSchema), maxTokens, temperature)
        } catch (e: BadRequest) {
            llm.call(messages, JSONObject().put("type", "json_object"), maxTokens, temperature)
        }
        val parsed = try {
            JsonText.parse(content)
        } catch (e: Exception) {
            // rare runaway output cut mid-JSON: one retry at temperature 0, then repair
            content = llm.call(messages, llm.schemaFormat("memory", prompts.recordSchema), maxTokens, 0.0)
            try { JsonText.parse(content) } catch (e2: Exception) { JsonText.repair(content) }
        }
        val record = Verify.verify(parsed, lines, detailRules, uncertainRules)
        val ol = JSONObject()
        for ((k, v) in lines) ol.put(k, v)
        record.put("ocr_lines", ol)
        return record
    }
}

/** The pure-code half of extract.py (no model calls), shared by the app and the parity tests. */
object Verify {
    val KINDS = listOf("booth", "shop", "restaurant", "health", "service", "directory",
        "event", "transport", "notice", "street", "indoor_space", "other")

    fun numberLines(lines: List<String>): LinkedHashMap<String, String> {
        val out = LinkedHashMap<String, String>()
        lines.map { it.trim() }.filter { it.isNotEmpty() }.forEachIndexed { i, l -> out["L%02d".format(i + 1)] = l }
        return out
    }

    // --- text checks ---------------------------------------------------------------

    private val OCR_FIX = mapOf('O' to '0', 'o' to '0', 'l' to '1', 'I' to '1', 'S' to '5', 'B' to '8')
    private val NON_DIGIT = Regex("\\D")
    private val NON_ALNUM = Regex("[^A-Z0-9]+")
    private val DIGITS = Regex("\\d+")
    private val ORDINAL = Regex("""\b([SOIlBZG])(?=(TH|ST|ND|RD)\s*FL|(TH|ST|ND|RD)\b)""")
    private val ORDINAL_FIX = mapOf('S' to '5', 'O' to '0', 'I' to '1', 'l' to '1', 'B' to '8', 'Z' to '2', 'G' to '6')

    fun digits(s: String) = s.map { OCR_FIX[it] ?: it }.joinToString("").replace(NON_DIGIT, "")
    fun norm(s: String) = s.uppercase().replace(NON_ALNUM, " ").trim()
    fun fixOrdinals(line: String) = ORDINAL.replace(line) { ORDINAL_FIX[it.value[0]].toString() }

    /** value appears in line, tolerating small OCR errors; numbers are never fuzzy. */
    fun fuzzyIn(value: String, line: String, threshold: Double = 0.8): Boolean {
        val v = norm(value)
        val l = norm(fixOrdinals(line))
        if (v.isEmpty()) return false
        val lineNums = DIGITS.findAll(l).map { it.value }.toSet()
        if (DIGITS.findAll(v).any { it.value !in lineNums }) return false
        if (l.contains(v)) return true
        val n = v.length
        if (n > l.length + 2) return false
        var best = 0.0
        for (i in 0 until maxOf(1, l.length - n + 1)) {
            val r = Difflib.ratio(v, l.substring(i, minOf(l.length, i + n)))
            if (r > best) best = r
        }
        return best >= threshold
    }

    fun phoneSupported(phone: String?, line: String): Boolean {
        if (phone.isNullOrEmpty()) return false
        val want = digits(phone)
        return want.length >= 6 && digits(line).contains(want)
    }

    /** The cited line plus contiguous windows around it (names wrap over 2-3 OCR lines). */
    private fun windows(lines: LinkedHashMap<String, String>, lid: String?, span: Int = 3): List<String> {
        val keys = lines.keys.toList()
        val i = keys.indexOf(lid)
        if (i < 0) return emptyList()
        val out = ArrayList<String>()
        for (start in maxOf(0, i - span + 1)..i)
            for (end in i + 1..minOf(keys.size, start + span))
                out.add(keys.subList(start, end).joinToString(" ") { lines[it]!! })
        return out
    }

    private fun reject(rejected: JSONArray, field: String, value: Any?, line: String?, lineText: String) {
        rejected.put(JSONObject().put("field", field).put("value", nullable(value)).put("line", nullable(line)).put("line_text", lineText))
    }

    fun verify(record: JSONObject, lines: LinkedHashMap<String, String>, detailRules: Boolean = true,
               uncertainRules: Boolean = true): JSONObject {
        val rejected = JSONArray()

        fun check(field: String, multiline: Boolean, ok: (String, String) -> Boolean) {
            val v = record.str(field) ?: return
            val lid = record.str("${field}_line")
            val line = lines[lid ?: ""] ?: ""
            val texts = if (multiline) windows(lines, lid) else listOf(line)
            if (line.isEmpty() || texts.none { ok(v, it) }) {
                reject(rejected, field, v, lid, line)
                record.put(field, JSONObject.NULL)
                record.put("${field}_line", JSONObject.NULL)
            }
        }
        check("name", true) { v, t -> fuzzyIn(v, t) }       // names may wrap; items/phones may not
        check("phone", false) { v, t -> phoneSupported(v, t) }
        check("hours", false) { v, t -> fuzzyIn(v, t) }

        // other_text may span many lines: each ' / ' part must appear somewhere in the OCR text
        record.str("other_text")?.let { ot ->
            val full = lines.values.joinToString(" ")
            val parts = ot.split("/").map { it.trim() }.filter { it.isNotEmpty() }
            val kept = parts.filter { fuzzyIn(it, full) }
            for (p in parts) if (p !in kept) reject(rejected, "other_text", p, null, "")
            record.put("other_text", nullable(kept.joinToString(" / ").ifEmpty { null }))
        }

        val good = JSONArray()
        for (it in record.arr("items").objects()) {
            val line = lines[it.optString("line", "")] ?: ""
            if (line.isNotEmpty() && fuzzyIn(it.optString("label", ""), line) && fuzzyIn(it.optString("value", ""), line)) good.put(it)
            else reject(rejected, "item", "${it.str("label")} -> ${it.str("value")}", it.str("line"), line)
        }
        record.put("items", good)

        if (record.str("kind") !in KINDS) record.put("kind", if (record.bool("useful")) "other" else JSONObject.NULL)

        cleanVisual(record, rejected, detailRules, uncertainRules)
        record.put("rejected", rejected)
        // not useful if no text evidence survived AND nothing worth finding is visible
        if (record.bool("useful") && listOf("name", "phone", "hours", "other_text").none { record.str(it) != null }
            && record.arr("items").length() == 0 && record.arr("objects").length() == 0 && record.arr("depictions").length() == 0)
            record.put("useful", false)
        return record
    }

    // --- visual checks ---------------------------------------------------------------

    private val PEOPLE = Regex("""\b(person|people|man|men|woman|women|child|children|kid|boy|girl|crowd|face|attendee|visitor|staff|guy|lady|hand|head)s?\b""", RegexOption.IGNORE_CASE)
    private val KEEP_PLURAL = setOf("stairs", "glasses", "scissors", "steps", "headphones", "pants", "news", "series")
    private val SIGNLIKE = Regex("""\b(neon|lit sign|illuminated sign|light[- ]?box|logo|lettering|letters|store sign|shop sign|signboard|name sign)\b""", RegexOption.IGNORE_CASE)
    private val VIDEO = Regex("""\b(video|showing|displaying|image|images|footage|game|ad|advert|advertisement|animation|moving)\b""", RegexOption.IGNORE_CASE)
    private val COSTUME = Regex("""\b(costume|costumed|performer|mascot|cosplay|living statue|dressed as)\b""", RegexOption.IGNORE_CASE)
    private val VOCAB = listOf("wet floor sign", "direction sign", "exit sign", "traffic sign", "traffic light", "street lamp", "drink cooler", "trash bin", "glass door", "qr code", "vending machine", "display case", "clothing rack", "fire extinguisher", "taxi", "bus", "car", "bicycle", "scooter", "truck", "cooler", "fridge", "bag", "poster", "banner", "billboard", "screen", "sign", "lamp", "door", "table", "chair", "sofa", "bench", "plant", "tree", "window", "doormat", "mat", "railing", "stairs", "escalator", "elevator", "kiosk", "counter", "column", "statue", "umbrella", "flag", "cone", "barrier", "mannequin", "box", "can", "bottle")
    private val PREP = Regex("""\b(on|in|at|near|above|below|with|by|behind|next|under|over|beside|inside|from|showing|of)\b""")
    private val WS = Regex("\\s+")

    /** 'chairs' -> 'chair', 'boxes' -> 'box', 'stairs' stays (last word only). */
    fun singular(name: String): String {
        val words = name.trim().split(WS).filter { it.isNotEmpty() }
        if (words.isEmpty()) return name
        var last = words.last()
        val head = words.dropLast(1)
        if (last in KEEP_PLURAL || last.length <= 3 || !last.endsWith("s") || last.endsWith("ss")) return name
        last = when {
            last.endsWith("xes") || last.endsWith("ches") || last.endsWith("shes") -> last.dropLast(2)
            last.endsWith("ies") -> last.dropLast(3) + "y"
            else -> last.dropLast(1)
        }
        return (head + last).joinToString(" ")
    }

    /** If the name is not in its own details but the head of the details names another known object, trust the details. */
    fun renameByDetails(name: String, details: String?): String {
        val d = (details ?: "").lowercase()
        if (d.isEmpty() || Regex("\\b" + Regex.escape(name) + "s?\\b").containsMatchIn(d)) return name
        val head = d.split(PREP, limit = 2)[0]
        for (v in VOCAB) {
            if (Regex("\\b" + Regex.escape(v) + "s?\\b").containsMatchIn(head)) return if (v == "cooler" || v == "fridge") "drink cooler" else v
        }
        return name
    }

    private fun markUncertain(objs: List<JSONObject>) {
        for ((i, o) in objs.withIndex()) {
            val why = ArrayList<String>()
            if ((o.str("visibility") ?: "").lowercase() == "unsure") why.add("model unsure")
            if (i >= 9) why.add("late in list")
            if (i >= 5 && o.str("distance") == "far") why.add("far and late in list")
            o.put("uncertain", why.isNotEmpty())
            if (why.isNotEmpty()) o.put("uncertain_why", why.joinToString(", "))
        }
    }

    private fun cleanVisual(record: JSONObject, rejected: JSONArray, detailRules: Boolean, uncertainRules: Boolean) {
        val seen = LinkedHashSet<String>()
        val objs = ArrayList<JSONObject>()
        for (o in record.arr("objects").objects()) {
            var name = (o.str("name") ?: "").trim().lowercase()
            if (name.isEmpty() || PEOPLE.containsMatchIn(name)) {
                if (name.isNotEmpty()) reject(rejected, "object", name, null, "person/empty")
                continue
            }
            name = singular(name)
            val d = o.str("details") ?: ""
            if (detailRules) {
                if (name == "screen" && SIGNLIKE.containsMatchIn(d) && !VIDEO.containsMatchIn(d)) name = "sign"
                if (name in setOf("statue", "sculpture", "figure", "monument", "mannequin") && COSTUME.containsMatchIn(d)) {
                    reject(rejected, "object", name, null, "details describe a person in costume")
                    continue
                }
                name = renameByDetails(name, d)
            }
            if (!seen.add(name)) continue
            val cnt = o.num("count", 1.0).toInt().let { if (it == 0) 1 else it }.coerceIn(1, 50)
            objs.add(o.copy().put("name", name).put("count", cnt))
        }
        val kept = objs.take(15)
        if (uncertainRules) markUncertain(kept)
        record.put("objects", JSONArray(kept))

        fun known(x: String): Boolean {
            val v = x.trim().lowercase()
            return v.isNotEmpty() && seen.any { v == it || it.contains(v) || v.contains(it) }
        }
        val rels = JSONArray()
        for (r in record.arr("relations").objects()) {
            val subj = singular((r.str("subject") ?: "").lowercase().trim().ifEmpty { "x" })
            val obj = singular((r.str("object") ?: "").lowercase().trim().ifEmpty { "x" })
            if (known(subj) && known(obj) && subj != obj)
                rels.put(JSONObject().put("subject", subj).put("relation", (r.str("relation") ?: "").trim().lowercase()).put("object", obj))
            else reject(rejected, "relation", "$subj ${r.str("relation")} $obj", null, "refers to an object not listed")
        }
        record.put("relations", rels)

        val deps = JSONArray()
        for (d in record.arr("depictions").objects()) {
            val content = (d.str("content") ?: "").trim()
            if (content.isEmpty()) continue
            val depicted = d.arr("depicted").strings().filter { it.isNotBlank() }.map { singular(it.trim().lowercase()) }.take(12)
            if (deps.length() < 6)
                deps.put(JSONObject().put("medium", d.str("medium") ?: "other").put("on", (d.str("on") ?: "").trim())
                    .put("content", content).put("depicted", JSONArray(depicted)))
        }
        record.put("depictions", deps)
        val sc = record.obj("scene")
        record.put("scene", JSONObject()
            .put("place_type", sc.str("place_type") ?: "unknown")
            .put("indoor", if (sc.has("indoor") && !sc.isNull("indoor")) sc.bool("indoor") else true)
            .put("lighting", sc.str("lighting") ?: "unknown"))
    }
}
