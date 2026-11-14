package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class EpisodeSummaryTest {
    private fun items(e: Episode): List<Doc> {
        val byKey = Fixture.sightings().associateBy { Episodes.key(it) }
        return Asker.docsFromSightings(e.members.mapNotNull { byKey[it] }).filter { it.type == "sighting" || it.type == "item" }
    }
    private fun s(text: String, vararg m: String) = JSONObject().put("text", text).put("memories", JSONArray(m.toList()))

    @Test
    fun uncitedPhoneAndHourAreRemoved() {
        val street = Episodes.group(Fixture.sightings())[1]                 // bus stop, bakery, basketball hoop
        val its = items(street)
        val bakery = "M" + (its.indexOfFirst { it.text.contains("Leipomo") } + 1)
        val raw = JSONObject().put("sentences", JSONArray()
            .put(s("You walked along Fredrikinkatu past Leipomo Kanelia.", bakery))
            .put(s("The bakery's number is 09 612 3344.", bakery))                    // backed
            .put(s("Its other number is 09 999 1111.", bakery))                       // invented phone
            .put(s("It opens at 6 on Sundays.", bakery))                              // invented hour
            .put(s("There was also a florist with phone 040 123 4567."))              // no citation at all
            .put(s("Bus 14 leaves in 3 min.", "M1"))
            .put(s("Leipomo Kanelia is on Fredrikinkatu [$bakery].")))                 // inline citation
        val (kept, dropped) = EpisodeSummarizer.verify(raw, its)
        assertTrue(kept, kept.contains("Leipomo Kanelia") && kept.contains("09 612 3344") && kept.contains("Bus 14"))
        assertFalse(kept, kept.contains("999") || kept.contains("Sundays") || kept.contains("florist"))
        assertTrue(kept, kept.contains("is on Fredrikinkatu.") && !kept.contains("[M"))
        assertEquals(3, dropped.size)
    }

    @Test
    fun oneCallPerSummaryAndCached() {
        val ep = Episodes.group(Fixture.sightings())[0]
        val reply = JSONObject().put("sentences", JSONArray().put(s("At home in the morning: keys on the kitchen counter and a note to call the dentist.", "M1", "M3")))
        CountingServer { _, _ -> JSONObject().put("choices", JSONArray().put(JSONObject().put("message",
            JSONObject().put("role", "assistant").put("content", reply.toString())).put("finish_reason", "stop"))).toString() }.use { srv ->
            val sum = EpisodeSummarizer(Llm(LlmConfig(srv.url + "/v1", "m", "k", "")))
            val text = sum.summarize(ep, items(ep))
            assertNotNull(text); assertEquals(1, srv.hits.get()); assertEquals(1, sum.calls)
            assertFalse("text only: no image is sent", srv.bodies[0].contains("image_url"))
            val store = SummaryStore(File("build/tmp/sum-${System.nanoTime()}").apply { mkdirs() })
            store.put(ep, text!!)
            assertEquals(text, store.get(ep))
            assertEquals("members changed -> summary is stale", null, store.get(ep.copy(members = ep.members + "x.jpg")))
        }
    }

    /** Live: >= 10 episodes (the fixture day twice), one request each, every kept sentence verified. */
    @Test
    fun liveTenEpisodes() {
        assumeTrue(System.getProperty("muisti.fixture") == "1")
        val key = System.getProperty("muisti.llmKey"); assumeTrue(!key.isNullOrEmpty())
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("UTC"))     // fixture clock is naive local time
        val llm = Llm(LlmConfig(System.getProperty("muisti.llmBaseUrl")!!, System.getProperty("muisti.llmModel")!!, key!!, key)).apply { gate = PrivacyGate.OPEN }
        val day1 = Fixture.sightings()
        val day2 = day1.map { JSONObject(it.toString()).put("seen_at", it.getLong("seen_at") + 86_400_000L).put("evidence_frame", "d2-" + it.getString("evidence_frame")) }
        val all = day1 + day2
        val byKey = all.associateBy { Episodes.key(it) }
        val eps = Episodes.group(all)
        val sum = EpisodeSummarizer(llm)
        var written = 0
        for (e in eps) {
            val its = Asker.docsFromSightings(e.members.mapNotNull { byKey[it] }).filter { it.type == "sighting" || it.type == "item" }
            val t = sum.summarize(e, its)
            println("SUMMARY ${e.id}: $t" + (if (t == null) "   dropped: ${sum.lastDropped}" else ""))
            if (!t.isNullOrBlank()) written++
        }
        println("episodes ${eps.size}, summarised $written, calls ${sum.calls}")
        assertTrue(eps.size >= 10 && written >= 10)
        assertEquals("one request per summary", eps.size, sum.calls)
    }
}
