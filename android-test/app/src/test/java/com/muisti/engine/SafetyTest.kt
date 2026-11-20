package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SafetyTest {
    private var t = 0L
    private fun scene(text: String, street: String = "Street ${t}") =
        Doc("sighting", (++t) * 3600_000L, "$t.jpg", null, "t", false, "", "notice", text = text).apply { this.street = street }

    /** P2.8 eval: scripted scenes (stored memory text) with the rule a person would expect, or none. */
    private val scenes = listOf(
        "Other text on sign: CAUTION WET FLOOR / MÄRKÄ LATTIA" to "wet_floor",
        "Visible things: yellow A-frame sign. Other text on sign: Slippery when wet" to "wet_floor",
        "Other text on sign: Hätäuloskäytävä / Emergency exit" to "fire_exit",
        "Other text on sign: PÄÄSY KIELLETTY" to "do_not_enter",
        "Other text on sign: Authorized personnel only" to "do_not_enter",
        "Other text on sign: No entry for cyclists" to "do_not_enter",
        "Other text on sign: KORKEAJÄNNITE HENGENVAARA" to "hazard",
        "Other text on sign: Construction site - keep out" to "hazard",
        "Other text on sign: DANGER Falling objects" to "hazard",
        // everyday signs that must not alarm
        "Name on sign: K-Market. Other text on sign: EXIT / ULOS" to null,
        "Other text on sign: Wet paint" to null,
        "Other text on sign: DANGER ZONE - the movie, in cinemas now" to null,
        "Other text on sign: Staff picks of the month" to null,
        "Other text on sign: Non-toxic paint for kids" to null,
        "Other text on sign: Warning: CCTV in use" to null,
        "Other text on sign: Kampin Apteekki, Avoinna 8-20" to null,
    )

    @Test
    fun evalPrecisionAndRecall() {
        val mon = SafetyMonitor({ SafetyRule.BUILT_IN })
        var tp = 0; var fp = 0; var fn = 0
        for ((text, want) in scenes) {
            val got = mon.textHits(scene(text)).map { it.rule.id }
            if (want != null && want in got) tp++ else if (want != null) fn++
            fp += got.count { it != want }
            println("${if ((want == null && got.isEmpty()) || (want != null && want in got && got.size == 1)) "OK" else "XX"} want=$want got=$got  $text")
        }
        val precision = tp.toDouble() / maxOf(1, tp + fp); val recall = tp.toDouble() / maxOf(1, tp + fn)
        println("safety eval: ${scenes.size} scenes, precision %.2f, recall %.2f".format(precision, recall))
        assertTrue(scenes.size >= 10)
        assertTrue("precision $precision", precision >= 0.8)
    }

    @Test
    fun noRepeatForTheSameSceneWithin10MinAndImageCheckOnlyOnHits() {
        val asked = ArrayList<String>()
        val mon = SafetyMonitor({ SafetyRule.BUILT_IN }, imageCheck = { d, r -> asked.add("${d.frame}:${r.id}"); true })
        fun at(min: Long, text: String, street: String) = Doc("sighting", min * 60_000L, "f$min.jpg", null, "t", false, "", "notice", text = text)
            .apply { this.street = street }
        val wet = "Other text on sign: CAUTION WET FLOOR"
        assertEquals(1, mon.evaluate(listOf(at(0, wet, "Otakaari")), 0).size)
        assertEquals("same rule, same place, 4 min later", 0, mon.evaluate(listOf(at(4, wet, "Otakaari")), 4 * 60_000L).size)
        assertEquals("another place", 1, mon.evaluate(listOf(at(5, wet, "Simonkatu")), 5 * 60_000L).size)
        val again = mon.evaluate(listOf(at(11, wet, "Otakaari")), 11 * 60_000L)
        assertEquals("after 10 min", 1, again.size)
        assertEquals(listOf("f11.jpg"), again[0].evidence)
        assertEquals(Notice.SAFETY, again[0].type)
        mon.evaluate(listOf(at(20, "Other text on sign: Kampin Apteekki", "Simonkatu")), 20 * 60_000L)
        assertEquals("image looked at only for text hits", listOf("f0.jpg:wet_floor", "f5.jpg:wet_floor", "f11.jpg:wet_floor"), asked)
        // the image says no -> no alert
        val strict = SafetyMonitor({ SafetyRule.BUILT_IN }, imageCheck = { _, _ -> false })
        assertEquals(0, strict.evaluate(listOf(at(30, wet, "X")), 30 * 60_000L).size)
    }

    @Test
    fun userRuleProposedThenStored() {
        val dir = File("build/tmp/safety-${System.nanoTime()}").apply { mkdirs() }
        scriptedModel(toolCall("add_safety_rule", JSONObject().put("name", "Peanuts").put("phrases", JSONArray(listOf("peanut", "maapähkinä", "may contain nuts")))
            .put("message", "This may contain peanuts."))).use { srv ->
            val llm = Llm(LlmConfig(srv.url + "/v1", "m", "k", "")).apply { gate = PrivacyGate.OPEN }
            val r = Agent(llm, prompts(), Asker(llm, prompts(), ParityTest.JvmImages, null)).apply { preSearch = false }
                .run("warn me if I see peanuts", emptyList(), emptyList(), 0L, extras = listOf(safetyRuleTool()))
            assertEquals(PendingAction.LABEL, r.label)
            assertTrue(r.answer, r.answer.contains("maapähkinä"))
            val rule = SafetyRule.fromJson(PendingAction.fromJson(r.parsed.getJSONObject("pending")).action.getJSONObject("rule"))
            val store = SafetyRuleStore(dir); store.add(rule)
            assertEquals(SafetyRule.BUILT_IN.size + 1, store.all().size)
            assertEquals("maapähkinä", rule.matches("Ainesosat: vehnä, MAAPÄHKINÄ, sokeri"))
        }
    }
}
