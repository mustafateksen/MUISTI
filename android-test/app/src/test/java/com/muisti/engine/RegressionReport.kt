package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Scores ask-tests exactly like eval/run_ask_tests.py and writes both the text summary and a JSON report with
 * per-question tool traces, so retrieval changes can be compared run by run (P1.8).
 */
object RegressionReport {
    class Score(val ok: Int, val total: Int, val seenOk: Int, val nSeen: Int, val trapOk: Int, val nTrap: Int,
                val halluc: Int, val wrong: Int, val avgLatency: Double, val avgCalls: Double) {
        fun summary() = "accuracy $ok/$total | answerable $seenOk/$nSeen | traps abstained $trapOk/$nTrap | hallucinated on traps $halluc | " +
            "answered but wrong $wrong | avg ${"%.1f".format(avgLatency)} s, ${"%.1f".format(avgCalls)} calls"
    }

    fun good(t: JSONObject, r: Answer): Boolean {
        val expect = t.getString("expect_label")
        val accept = t.arr("accept_labels").strings().ifEmpty { listOf(expect) }
        fun has(s: String) = s.lowercase().split("|").any { r.answer.lowercase().contains(it) }
        return r.label in accept &&
            (r.label != "SEEN" || t.arr("must_contain").strings().all { has(it) }) &&
            !(r.label == "SEEN" && t.arr("must_not_contain").strings().any { has(it) })
    }

    fun run(qs: List<JSONObject>, outBase: File, ask: (JSONObject) -> Answer): Score {
        var ok = 0; var seenOk = 0; var trapOk = 0; var halluc = 0; var wrong = 0; var lat = 0.0; var calls = 0
        val text = StringBuilder(); val rows = JSONArray()
        for (t in qs) {
            val r = ask(t)
            lat += r.latencyS; calls += r.calls
            val g = good(t, r); val expect = t.getString("expect_label")
            if (g) ok++
            if (expect == "SEEN" && g) seenOk++
            if (expect == "DONT_KNOW" && g) trapOk++
            if (expect == "DONT_KNOW" && r.label == "SEEN") halluc++
            if (expect != "DONT_KNOW" && r.label == "SEEN" && !g) wrong++
            val tools = r.why.substringAfter("| tools: ", "").split(", ").filter { it.isNotBlank() }
            val line = "${if (g) "OK " else "XX "} [${r.label.padEnd(9)}] ${t.getString("q")}\n      -> ${r.answer}   (${r.why})"
            println(line); text.append(line).append('\n')
            rows.put(JSONObject().put("q", t.getString("q")).put("expect", expect).put("label", r.label).put("ok", g)
                .put("answer", r.answer).put("why", r.why).put("tools", JSONArray(tools)).put("calls", r.calls)
                .put("latency_s", r.latencyS).put("used", JSONArray(r.used))
                .put("evidence", JSONArray(r.evidence.filter { it.id in r.used }.map { JSONObject().put("id", it.id).put("frame", it.frame).put("text", it.text.take(240)) })))
        }
        val nSeen = qs.count { it.getString("expect_label") == "SEEN" }
        val nTrap = qs.count { it.getString("expect_label") == "DONT_KNOW" }
        val s = Score(ok, qs.size, seenOk, nSeen, trapOk, nTrap, halluc, wrong, lat / qs.size, calls.toDouble() / qs.size)
        println(s.summary())
        outBase.parentFile?.mkdirs()
        File(outBase.path + ".txt").writeText(text.append(s.summary()).toString())
        File(outBase.path + ".json").writeText(JSONObject().put("summary", s.summary())
            .put("accuracy", ok).put("total", qs.size).put("answerable_ok", seenOk).put("answerable", nSeen)
            .put("traps_abstained", trapOk).put("traps", nTrap).put("hallucinated_on_traps", halluc).put("answered_wrong", wrong)
            .put("avg_latency_s", s.avgLatency).put("avg_calls", s.avgCalls).put("questions", rows).toString(1))
        return s
    }
}
