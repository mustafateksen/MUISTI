package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class ConfirmTest {
    @Test
    fun spokenYesNo() {
        for (y in listOf("yes", "Yeah, do it.", "ok", "Sure", "go ahead please", "kyllä")) assertEquals(y, true, Confirmations.answer(y))
        for (n in listOf("no", "No thanks", "cancel", "don't", "wait", "never mind")) assertEquals(n, false, Confirmations.answer(n))
        for (o in listOf("where are my keys", "what time is it", "now")) assertNull(o, Confirmations.answer(o))
    }

    private fun agentWith(srv: CountingServer): Agent {
        val llm = Llm(LlmConfig(srv.url + "/v1", "m", "k", "")).apply { gate = PrivacyGate.OPEN }
        return Agent(llm, prompts(), Asker(llm, prompts(), object : Images { override fun downscale(jpeg: ByteArray, longSide: Int) = jpeg }, null))
            .apply { preSearch = false }
    }

    @Test
    fun createZoneIsOnlyProposed() {
        scriptedModel(toolCall("create_zone", JSONObject().put("name", "Home").put("radius_m", 120))).use { srv ->
            val r = agentWith(srv).run("don't record at home", emptyList(), emptyList(), 0L,
                extras = listOf(createZoneTool { Triple(60.17, 24.94, "Mannerheimintie") }))
            assertEquals(PendingAction.LABEL, r.label)
            val p = PendingAction.fromJson(r.parsed.getJSONObject("pending"))
            assertEquals("create_zone", p.action.getString("type"))
            assertEquals(120.0, p.action.getDouble("radius_m"), 0.0)
            assertEquals(60.17, p.action.getDouble("lat"), 0.0)
            assertTrue(r.answer, r.answer.contains("Home") && r.answer.endsWith("?"))
        }
    }

    @Test
    fun noLocationNoProposal() {
        scriptedModel(toolCall("create_zone", JSONObject().put("name", "Home")),
            toolCall("answer", JSONObject().put("label", "CHAT").put("text", "I need your location first.").put("evidence", org.json.JSONArray()))).use { srv ->
            val r = agentWith(srv).run("don't record here", emptyList(), emptyList(), 0L, extras = listOf(createZoneTool { null }))
            assertEquals("CHAT", r.label)
            assertTrue(JSONObject(srv.bodies[1]).toString().contains("No location right now"))
        }
    }

    @Test
    fun liveModelProposesAZone() {
        assumeTrue(System.getProperty("muisti.fixture") == "1")
        val key = System.getProperty("muisti.llmKey"); assumeTrue(!key.isNullOrEmpty())
        val llm = Llm(LlmConfig(System.getProperty("muisti.llmBaseUrl")!!, System.getProperty("muisti.llmModel")!!, key!!, key)).apply { gate = PrivacyGate.OPEN }
        val agent = Agent(llm, prompts(), Asker(llm, prompts(), ParityTest.JvmImages, null))
        var ok = 0
        for (q in listOf("don't record at home", "never record anything here, this is my doctor's office", "please stop recording at this place from now on")) {
            val r = agent.run(q, emptyList(), Fixture.docs(), Fixture.now(), extras = listOf(createZoneTool { Triple(60.17, 24.94, null) }))
            println("ZONE [${r.label}] '$q' -> ${r.answer}")
            if (r.label == PendingAction.LABEL) ok++
        }
        assertEquals(3, ok)
    }
}
