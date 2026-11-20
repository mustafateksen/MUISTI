package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** The answer verifier's number rule, through the agent with a scripted model and the fixture memory. */
class VerifierTest {
    private fun run(answer: String): Answer {
        val search = toolCall("search_memory", JSONObject().put("query", "Leipomo Kanelia bakery").put("synonyms", JSONArray()).put("what", "hours").put("minutes", JSONObject.NULL))
        val ans = toolCall("answer", JSONObject().put("label", "SEEN").put("text", answer).put("evidence", JSONArray().put("E1"))
            .put("quotes", JSONArray().put("La 9-15")).put("support", "stated"))
        return scriptedModel(search, ans, ans).use { srv ->
            val llm = Llm(LlmConfig(srv.url + "/v1", "m", "k", "")).apply { gate = PrivacyGate.OPEN }
            Agent(llm, prompts(), Asker(llm, prompts(), ParityTest.JvmImages, null)).apply { preSearch = false }
                .run("When does the bakery close on Saturday?", emptyList(), Fixture.docs(), Fixture.now())
        }
    }

    @Test
    fun wholeHourIsTheSameNumber() = assertEquals("SEEN", run("Leipomo Kanelia closes at 15:00 on Saturday.").label)

    @Test
    fun inventedHourIsRejected() = assertEquals("DONT_KNOW", run("Leipomo Kanelia closes at 16:00 on Saturday.").label)

    @Test
    fun inventedMinutesAreRejected() = assertEquals("DONT_KNOW", run("Leipomo Kanelia closes at 15:30 on Saturday.").label)
}
