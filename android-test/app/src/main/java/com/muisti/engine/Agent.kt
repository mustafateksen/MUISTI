package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The assistant as a tool-calling agent (Nemotron native tool calling).
 *
 * The model reads the conversation, calls tools (search_memory, recent, list_names, look_now,
 * forget) as many times as it needs, and must finish with `answer`. Everything a tool returns is
 * registered as evidence E1, E2, ... and the final answer is checked by code exactly like the
 * classic pipeline: quotes must appear in the cited evidence, numbers must match, object-only
 * answers get a second look at the stored frame. A failed check is sent back to the model once
 * ("your quote was not found"); if it fails again the reply is an honest "not sure".
 */
/** An event to put in the phone calendar (start/end in epoch ms, local time). */
class CalendarEvent(val title: String, val startMs: Long, val endMs: Long, val location: String?, val note: String)

class Agent(private val llm: Llm, private val prompts: Prompts, private val asker: Asker) {

    var maxRounds = 4   // the last round must be `answer`
    /** Where the last run spent its time ("llm 820ms", "search_memory 40ms", ...), for tuning. */
    val timings = ArrayList<String>()
    /** Search with the raw question before the first model call (saves a round trip). */
    var preSearch = true

    fun run(question: String, history: List<Pair<String, String>>, docs: List<Doc>, now: Long,
            liveFrame: ByteArray? = null, onForget: (Int) -> Int = { 0 },
            heard: List<String> = emptyList(),
            onCalendar: (CalendarEvent) -> String = { "Calendar is not available." },
            extras: List<ExtraTool> = emptyList()): Answer {
        val t0 = System.currentTimeMillis()
        timings.clear()
        var calls = 0
        val evidence = ArrayList<Doc>()                  // E1 = evidence[0]
        val trace = ArrayList<String>()
        var retried = false

        fun ev(d: Doc): String {
            val i = evidence.indexOf(d).let { if (it >= 0) it else { evidence.add(d); evidence.size - 1 } }
            val where = d.street?.let { ", on $it" } ?: ""
            return "E${i + 1} (seen ${asker.ago(now, d.seenAt)}$where): ${d.text}"
        }
        fun result(label: String, text: String, used: List<String> = emptyList(), why: String = "", extra: JSONObject = JSONObject()): Answer {
            val evs = evidence.mapIndexed { i, d -> Evidence("E${i + 1}", d.text, d.frame, d.seenAt, 1.0, d.lat, d.lon, d.street) }
            return Answer(question, label, text, used, evs, (why + " | tools: " + trace.joinToString(", ")).trim(), calls,
                (System.currentTimeMillis() - t0) / 1000.0, extra)
        }

        val clock = SimpleDateFormat("EEEE d MMMM yyyy, HH:mm", Locale.US).format(Date(now))
        val msgs = JSONArray().put(JSONObject().put("role", "system").put("content",
            prompts.agentPrompt + (if (extras.isEmpty()) "" else "\nMore tools on this phone:\n" + extras.joinToString("\n") { it.prompt }) +
                "\nCurrent local date and time: $clock. Memories stored: ${docs.count { it.type == "sighting" }}."))
        val tools = ExtraTool.merge(prompts.agentTools, extras)
        for ((q, a) in history) {
            msgs.put(JSONObject().put("role", "user").put("content", q))
            msgs.put(JSONObject().put("role", "assistant").put("content", a))
        }
        // speech: the recognizer's other hearings, so the model can fix "not eat" -> "note it" from context
        val others = heard.map { it.trim() }.filter { it.isNotEmpty() && !it.equals(question.trim(), ignoreCase = true) }.distinct().take(4)
        msgs.put(JSONObject().put("role", "user").put("content",
            if (others.isEmpty()) question
            else question + "\n[spoken; the speech recognizer also heard: " + others.joinToString(" | ") { "\"$it\"" } + "]"))
        val qvec by lazy { asker.semanticSetup(question, docs) }

        // Speed: search memory with the question itself BEFORE the first model call and hand the result
        // over as if the model had asked for it. Most questions are then answered in one call instead of
        // "decide to search" -> "search" -> "answer". The model can still call any tool afterwards.
        if (preSearch && docs.isNotEmpty()) {
            val tp = System.currentTimeMillis()
            val args = JSONObject().put("query", question).put("synonyms", JSONArray()).put("what", "other").put("minutes", JSONObject.NULL)
            val found = searchMemory(args, docs, now, qvec, ::ev)
            val call = JSONObject().put("id", "pre_search").put("type", "function")
                .put("function", JSONObject().put("name", "search_memory").put("arguments", args.toString()))
            msgs.put(JSONObject().put("role", "assistant").put("content", "").put("tool_calls", JSONArray().put(call)))
            msgs.put(JSONObject().put("role", "tool").put("tool_call_id", "pre_search").put("name", "search_memory").put("content", found))
            trace.add("pre_search")
            timings.add("pre_search ${System.currentTimeMillis() - tp}ms")
        }

        for (round in 0 until maxRounds) {
            val tl = System.currentTimeMillis()
            // last round: the model must answer with what it has (it used to keep searching on follow-ups)
            val last = round == maxRounds - 1
            if (last) msgs.put(JSONObject().put("role", "user").put("content",
                "Answer now with the evidence you have (or say you don't know)."))
            val msg = llm.chatTools(msgs, tools,
                if (last) RawJson("{\"type\": \"function\", \"function\": {\"name\": \"answer\"}}") else RawJson("\"required\"")); calls++
            timings.add("llm ${System.currentTimeMillis() - tl}ms")
            val toolCalls = msg.optJSONArray("tool_calls") ?: JSONArray()
            if (toolCalls.length() == 0) {
                // no tool call: treat plain text as a chat reply (it must not claim sightings: no evidence)
                return result("CHAT", msg.str("content") ?: "Sorry, could you say that again?", why = "no tool call")
            }
            msgs.put(JSONObject().put("role", "assistant").put("content", msg.str("content") ?: "").put("tool_calls", toolCalls))
            for (tc in toolCalls.objects()) {
                val fn = tc.obj("function")
                val name = fn.str("name") ?: ""
                val args = runCatching { JSONObject(fn.str("arguments") ?: "{}") }.getOrElse { JSONObject() }
                trace.add(name)
                if (name == "answer") {
                    val verdict = verify(question, args, evidence, ::lookAgainCounted)
                    calls += lookCalls; lookCalls = 0
                    if (verdict.retry != null && !retried) {
                        retried = true
                        msgs.put(tool(tc, "Not accepted: ${verdict.retry} Fix it and call answer again."))
                        continue
                    }
                    return result(verdict.label, verdict.text, verdict.used, verdict.why)
                }
                val tt = System.currentTimeMillis()
                val out = when (name) {
                    "search_memory" -> searchMemory(args, docs, now, qvec, ::ev)
                    "recent" -> recent(args.num("minutes", 10.0), docs, now, ::ev)
                    "list_names" -> listNames(args.num("minutes", 0.0), docs, now, ::ev)
                    "look_now" -> if (liveFrame == null) "The camera has no live view right now." else {
                        val seen = asker.liveLook(args.str("question") ?: question, liveFrame); calls++
                        val d = Doc("live", now, null, null, "live", false, "live view", "live", text = "LIVE VIEW right now: $seen")
                        ev(d)
                    }
                    "add_to_calendar" -> addToCalendar(args, evidence, onCalendar)
                    "forget" -> {
                        val m = args.num("minutes", 10.0).toInt().coerceAtLeast(1)
                        val n = onForget(m)
                        return result("FORGOT", "Okay, I forgot everything from the last $m minutes.", why = "forgot $m min ($n frames)",
                            extra = JSONObject().put("minutes", m))
                    }
                    else -> when (val x = extras.firstOrNull { it.name == name }?.run(args, ToolCtx(question, now, docs, liveFrame, ::ev))) {
                        null -> "Unknown tool $name."
                        is ToolOut.Text -> x.text
                        is ToolOut.Final -> {
                            val ids = x.used.map { d -> ev(d).substringBefore(' ') }
                            return result(x.label, x.text, ids, why = "tool $name", extra = x.extra)
                        }
                    }
                }
                timings.add("$name ${System.currentTimeMillis() - tt}ms")
                msgs.put(tool(tc, out))
            }
        }
        return result("DONT_KNOW", "Sorry, I couldn't work that out.", why = "no answer after $maxRounds rounds")
    }

    /**
     * Calendar entries must come from a sign: the day of the month and the hour of `start` have to be
     * written in the cited evidence (18:00 or 6 pm), otherwise nothing is added and the model is told why.
     */
    private fun addToCalendar(a: JSONObject, evidence: List<Doc>, onCalendar: (CalendarEvent) -> String): String {
        // The model copies month/day/time from the sign; the year is computed here (this year, or next year
        // if that day has already passed) so the model never has to "guess" one.
        fun hm(s: String?): Pair<Int, Int>? = s?.trim()?.split(":")?.takeIf { it.size == 2 }
            ?.let { (h, m) -> h.toIntOrNull()?.let { hh -> m.toIntOrNull()?.let { mm -> hh to mm } } }?.takeIf { it.first in 0..23 && it.second in 0..59 }
        val month = a.num("month").toInt(); val dayIn = a.num("day").toInt()
        val st = hm(a.str("start_time"))
        if (month !in 1..12 || dayIn !in 1..31 || st == null) return "Not added: give month (1-12), day and start_time HH:MM from the sign."
        val nowCal = java.util.Calendar.getInstance()
        fun at(year: Int, t: Pair<Int, Int>) = java.util.Calendar.getInstance().apply {
            clear(); set(year, month - 1, dayIn, t.first, t.second)
        }.time
        var year = nowCal.get(java.util.Calendar.YEAR)
        val today0 = java.util.Calendar.getInstance().apply { set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0) }.time
        if (at(year, 23 to 59).before(today0)) year += 1
        val start = at(year, st)
        val end = hm(a.str("end_time"))?.let { at(year, it) }?.takeIf { it.after(start) }
        val eid = Regex("E\\d+")
        val cited = a.arr("evidence").strings().filter { eid.matches(it) && it.substring(1).toInt() in 1..evidence.size }
            .map { evidence[it.substring(1).toInt() - 1] }
        if (cited.isEmpty()) return "Not added: cite the evidence id of the sign that shows the event."
        val text = cited.joinToString(" ") { it.text }.lowercase()
        val cal = java.util.Calendar.getInstance().apply { time = start }
        val day = cal.get(java.util.Calendar.DAY_OF_MONTH)
        val hour = cal.get(java.util.Calendar.HOUR_OF_DAY)
        val h12 = if (hour % 12 == 0) 12 else hour % 12
        fun has(n: Int) = Regex("(?<!\\d)0?$n(?!\\d)").containsMatchIn(text)
        if (!has(day)) return "Not added: day $day is not written on the cited sign. Tell the user the date is not on it."
        if (!has(hour) && !has(h12)) return "Not added: the time $hour:00 is not written on the cited sign. Tell the user the time is not on it."
        val ev = CalendarEvent(a.str("title") ?: "Event", start.time, (end ?: Date(start.time + 3_600_000)).time,
            a.str("location"), "Added by MUISTI from a sign you saw: " + cited.first().text.take(200))
        return onCalendar(ev)
    }

    private fun tool(tc: JSONObject, content: String) = JSONObject().put("role", "tool")
        .put("tool_call_id", tc.optString("id")).put("name", tc.obj("function").optString("name")).put("content", content)

    // --- tools ----------------------------------------------------------------------

    private fun searchMemory(a: JSONObject, docs: List<Doc>, now: Long, qvec: FloatArray?, ev: (Doc) -> String): String {
        val minutes = a.num("minutes", 0.0)
        val parsed = JSONObject()
            .put("target", a.str("query") ?: "").put("category", JSONObject.NULL)
            .put("attribute", a.str("what")?.takeIf { it in Asker.ATTRIBUTES } ?: "other")
            .put("time", when { minutes <= 0 -> "any"; minutes <= 20 -> "just_now"; minutes <= 60 -> "last_hour"; else -> "today" })
            .put("synonyms", a.arr("synonyms"))
        val cand = asker.search(parsed, docs, now, k = 20, qvec = qvec)
        // same gate as the classic pipeline: nothing relevant enough -> say so, so the model abstains
        if (cand.isEmpty() || cand[0].first < 0.9) return "No relevant memories found for '${a.str("query")}'."
        val hits = if (!hybrid) cand.take(5) else fuse(a.str("query") ?: "", parsed, cand, docs, now, qvec)
        val lines = hits.map { ev(it.second) }
        val attr = parsed.optString("attribute")
        val note = when {
            attr == "phone" && hits.none { it.second.phone != null } -> "\nNote: none of these shows a phone number."
            attr == "hours" && hits.none { it.second.hours != null } -> "\nNote: none of these shows opening hours."
            else -> ""
        }
        return lines.joinToString("\n") + note
    }

    /** Hybrid retrieval (P2.6): RRF over keyword scoring, text vectors, image vectors and (time questions) recency. */
    var hybrid = true
    /** Phone only: frame names ranked by MobileCLIP image similarity to a search text. */
    var imageRank: ((String) -> List<String>)? = null
    /** Optional cross-encoder, used only when the two best fused results are tied. */
    var reranker: Reranker? = null
    var reranks = 0; private set

    private fun fuse(query: String, parsed: JSONObject, cand: List<Pair<Double, Doc>>, docs: List<Doc>, now: Long, qvec: FloatArray?): List<Pair<Double, Doc>> {
        val lex = cand.filter { it.first > 0 }.map { it.second }
        val sem = if (qvec == null) emptyList() else docs.mapNotNull { d -> d.vec?.let { v -> var s = 0.0; for (i in v.indices) s += v[i] * qvec[i]; d to s } }
            .filter { it.second >= 0.35 }.sortedByDescending { it.second }.take(20).map { it.first }
        val img = imageRank?.let { r -> runCatching { r(query) }.getOrDefault(emptyList()) }?.mapNotNull { f ->
            docs.firstOrNull { it.frame == f && (it.type == "object" || it.type == "sighting") } }?.distinct() ?: emptyList()
        val lists = mutableListOf(lex to 1.0, sem to 1.0, img to 1.0)
        if (parsed.optString("time") != "any") lists.add(docs.filter { it.seenAt <= now }.sortedByDescending { it.seenAt }.take(20) to 0.5)
        var fused = Hybrid.rrf(lists).filter { (d, _) -> d in lex || d in sem }     // recency/image alone never brings a memory in
        val rr = reranker
        if (rr != null && Hybrid.close(fused)) {
            val top = fused.take(8)
            rr.scores(query, top.map { it.first.text })?.let { s ->
                reranks++
                fused = top.zip(s).sortedByDescending { it.second }.map { it.first } + fused.drop(8)
            }
        }
        val lexScore = cand.associate { it.second to it.first }
        return fused.take(5).map { (d, _) -> (lexScore[d] ?: 0.0) to d }
    }

    private fun recent(minutes: Double, docs: List<Doc>, now: Long, ev: (Doc) -> String): String {
        val pool = docs.filter { it.type == "sighting" && it.seenAt <= now && (now - it.seenAt) / 60000.0 <= minutes }.sortedBy { it.seenAt }
        if (pool.isEmpty()) return "Nothing was seen in the last ${minutes.toInt()} minutes."
        // episodes first (what the user was doing, where), then sampled memories for detail
        val eps = docs.filter { it.type == "episode" && it.seenAt <= now && (now - it.seenAt) / 60000.0 <= minutes }.sortedBy { it.seenAt }.takeLast(6)
        val step = maxOf(1, pool.size / 12)
        return (eps + pool.filterIndexed { i, _ -> i % step == 0 }.takeLast(12)).joinToString("\n") { ev(it) }
    }

    private fun listNames(minutes: Double, docs: List<Doc>, now: Long, ev: (Doc) -> String): String {
        val pool = if (minutes > 0) docs.filter { it.seenAt <= now && (now - it.seenAt) / 60000.0 <= minutes } else docs
        val names = asker.namesSeen(pool)
        if (names.isEmpty()) return "No names or signs were read."
        return names.take(15).joinToString("\n") { (n, d) -> "\"$n\" -> " + ev(d) }
    }

    // --- verification (same rules as Asker.ask) -----------------------------------------

    private var lookCalls = 0
    private fun lookAgainCounted(d: Doc): Pair<Boolean, String> { lookCalls++; return asker.lookAgain(d) }

    private class Verdict(val label: String, val text: String, val used: List<String>, val why: String, val retry: String? = null)

    private fun verify(question: String, a: JSONObject, evidence: List<Doc>, look: (Doc) -> Pair<Boolean, String>): Verdict {
        val label = a.str("label") ?: "DONT_KNOW"
        val text = a.str("text") ?: ""
        if (label == "CHAT") {
            // a chat reply must not lean on memories
            return if (a.arr("evidence").length() == 0) Verdict("CHAT", text, emptyList(), "small talk")
            else Verdict("CHAT", text, emptyList(), "chat (evidence ignored)")
        }
        if (label != "SEEN") return Verdict("DONT_KNOW", text.ifEmpty { "I don't remember seeing that." }, emptyList(), "model abstained")
        val ids = a.arr("evidence").strings()
        if (a.str("support") != "stated" && a.str("observations") != null)
            return Verdict("UNSURE", "I'm not sure. ${a.str("observations")}", ids, "answer was inferred, not stated in evidence")
        val eid = Regex("E\\d+")
        val used = ids.filter { eid.matches(it) && it.substring(1).toInt() in 1..evidence.size }.map { evidence[it.substring(1).toInt() - 1] }
        val cited = used.map { it.text }
        val quotes = a.arr("quotes").strings().filter { it.isNotBlank() }
        val badQ = quotes.filter { q -> cited.none { Verify.fuzzyIn(q, it) } }
        if (cited.isEmpty() || quotes.isEmpty() || badQ.isNotEmpty())
            return Verdict("DONT_KNOW", "I'm not sure. I can show you the closest thing I saw.", emptyList(),
                "verifier rejected quotes ${badQ.ifEmpty { quotes }}",
                retry = "every quote must be copied exactly from the evidence item it cites (bad: ${badQ.ifEmpty { quotes }}).")
        // Numbers: every sentence's numbers must appear TOGETHER in one cited item. Checking them against all
        // cited items at once let the model glue "18" from one poster and "12" from another into fake hours.
        val num = Regex("\\d+")
        // an item's own time ("seen at 08:02", shown to the model with it) is evidence too
        val hhmm = SimpleDateFormat("HH:mm", Locale.US)
        val perItem = used.map { d -> num.findAll(d.text + " " + hhmm.format(Date(d.seenAt))).map { it.value }.toSet() }
        val badSentence = text.split(Regex("(?<=[.!?])\\s+")).firstOrNull { sentence ->
            // "15:00" for a sign's "9-15" adds no new number: a whole hour's ":00" is not checked
            val ns = num.findAll(sentence.replace(Regex("""\b(\d{1,2})[:.]00\b"""), "$1")).map { it.value }.toSet()
            ns.isNotEmpty() && perItem.none { it.containsAll(ns) }
        }
        if (badSentence != null)
            return Verdict("DONT_KNOW", "I'm not sure about the exact numbers. I can show you the frame.", emptyList(),
                "verifier: numbers of '$badSentence' are not together in one cited item",
                retry = "the numbers in '$badSentence' do not all come from the same evidence item; never combine numbers from different signs.")
        // visual facts only (no OCR text, no live view): look again at the stored frame
        // re-check the thing the user asked about first (as Asker does), then the most-seen one
        val objDocs = used.filter { it.type == "object" || it.type == "depiction" }
            .sortedWith(compareBy<Doc>({ -asker.tokMatch(question, it.name) }, { -it.support }))
        val textBacked = used.any { it.type != "object" && it.type != "depiction" }
        if (objDocs.isNotEmpty() && !textBacked) {
            val notes = ArrayList<String>()
            for (d in objDocs.take(3)) {
                val (ok, note) = look(d)
                notes.add("${d.name}@${d.frame}: ${if (ok) "yes" else "no"}")
                if (ok) {
                    asker.mediumGuard(question, used)?.let { return Verdict("DONT_KNOW", it, ids, "medium mismatch (code)") }
                    return Verdict("SEEN", text, ids, "verified ${quotes.size} quote(s) + visual re-check (${d.name}): $note")
                }
            }
            val d = objDocs[0]
            val what = if (d.type == "depiction") "a picture (${d.content}) on a ${d.medium}" else "a ${d.name}"
            return Verdict("DONT_KNOW", "I noted $what earlier, but looking at the photos again I'm not sure. I can show you the frames.",
                emptyList(), "visual re-check failed: ${notes.joinToString("; ")}")
        }
        asker.mediumGuard(question, used)?.let { return Verdict("DONT_KNOW", it, ids, "medium mismatch (code)") }
        return Verdict("SEEN", text, ids, "verified ${quotes.size} quote(s)")
    }
}
