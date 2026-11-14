package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A fake Nemotron: answers each chat request with the next scripted assistant message. */
fun scriptedModel(vararg msgs: JSONObject): CountingServer {
    val queue = ArrayDeque(msgs.toList())
    return CountingServer { _, _ ->
        val m = queue.removeFirstOrNull() ?: JSONObject().put("role", "assistant").put("content", "done")
        JSONObject().put("choices", JSONArray().put(JSONObject().put("message", m).put("finish_reason", "stop"))).toString()
    }
}

fun toolCall(name: String, args: JSONObject) = JSONObject().put("role", "assistant").put("content", "")
    .put("tool_calls", JSONArray().put(JSONObject().put("id", "c1").put("type", "function")
        .put("function", JSONObject().put("name", name).put("arguments", args.toString()))))

fun prompts() = Prompts(File(File(System.getProperty("muisti.repo") ?: "../.."), "nemotron/docs/prompts.json").readText())

class NotesTest {
    @Test
    fun speechFix() {
        assertEquals("note it", SpeechFix.correct("not eat", emptyList()))
        assertEquals("note it", SpeechFix.correct("Not eat.", emptyList()))
        assertEquals("note it", SpeechFix.correct("knot it", emptyList()))
        assertEquals("note that", SpeechFix.correct("not dat", emptyList()))
        // real sentences are left alone
        for (s in listOf("not that one", "now it's raining", "note it", "what did I eat", "no it was the other sign", "not today"))
            assertEquals(s, SpeechFix.correct(s, emptyList()))
        // with alternatives the agent decides (it sees all hearings)
        assertEquals("not eat", SpeechFix.correct("not eat", listOf("note it")))
    }

    @Test
    fun storeSearchForget() {
        val dir = File("build/tmp/notes-${System.nanoTime()}")
        val s = NoteStore(dir)
        s.add("My car is on level 3, spot B12", 1000, null, 60.1, 24.9, "Annankatu")
        s.add("Buy oat milk", 2000, byteArrayOf(1, 2))
        val again = NoteStore(dir)
        assertEquals(2, again.all().size)
        val d = again.docs()
        assertEquals("note", d[0].type)
        assertTrue(Verify.fuzzyIn("level 3, spot B12", d[0].text))
        assertEquals("n2.jpg", again.all()[1].frame); assertTrue(File(again.frameDir, "n2.jpg").exists())
        again.forgetSince(1500)
        assertEquals(1, again.all().size); assertTrue(!File(again.frameDir, "n2.jpg").exists())
    }

    @Test
    fun agentCallsNoteToolAndTheToolListIsMerged() {
        scriptedModel(toolCall("note", JSONObject().put("text", "My car is on level 3").put("include_view", false))).use { srv ->
            val llm = Llm(LlmConfig(srv.url + "/v1", "m", "k", "")).apply { gate = PrivacyGate.OPEN }
            val asker = Asker(llm, prompts(), object : Images { override fun downscale(jpeg: ByteArray, longSide: Int) = jpeg }, null)
            val saved = ArrayList<String>()
            val r = Agent(llm, prompts(), asker).apply { preSearch = false }.run("note that my car is on level 3", emptyList(), emptyList(), 0L,
                extras = listOf(noteTool { t, _ -> saved.add(t); Note(1, 0, t, null, null, null, null) }))
            assertEquals("NOTED", r.label)
            assertEquals(listOf("My car is on level 3"), saved)
            val body = JSONObject(srv.bodies[0])
            val names = body.getJSONArray("tools").objects().map { it.getJSONObject("function").getString("name") }
            assertTrue(names.containsAll(listOf("search_memory", "answer", "note")))
            assertTrue(body.getJSONArray("messages").getJSONObject(0).getString("content").contains("- note:"))
        }
    }
}
