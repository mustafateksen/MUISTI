package com.muisti.engine

import com.muisti.privacy.PrivacyGate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class VisualSearchTest {
    private fun v(vararg x: Float) = floatArrayOf(*x)

    @Test
    fun storeSearchDeleteSurvivesRestart() {
        val f = File("build/tmp/iv-${System.nanoTime()}.bin")
        val s = ImageVectors(f)
        s.put(1, v(1f, 0f, 0f)); s.put(2, v(0.8f, 0.6f, 0f)); s.put(3, v(0f, 0f, 1f))
        assertEquals(listOf(1, 2, 3), s.search(v(1f, 0f, 0f), 3).map { it.first })
        s.delete(setOf(1))
        val again = ImageVectors(f)
        assertEquals(2, again.size())
        assertEquals(2, again.search(v(1f, 0f, 0f), 1)[0].first)
        assertEquals(1.0, ImageVectors.dot(again.get(3)!!, v(0f, 0f, 1f)), 1e-6)
    }

    @Test
    fun deletingAFrameDeletesItsVector() {
        val dir = File("build/tmp/ms-${System.nanoTime()}")
        val store = MemoryStore(dir)
        val rec = JSONObject().put("useful", true)
        val a = store.addFrame(1000, rec, emptyList(), byteArrayOf(1), null, imageVec = v(1f, 0f))
        val b = store.addFrame(2000, rec, emptyList(), byteArrayOf(2), null, imageVec = v(0f, 1f))
        store.deleteFrames(setOf(a))
        assertEquals(1, store.vectors.size())
        store.forget(1500)
        assertEquals(0, store.vectors.size())
        assertTrue(b > a)
    }

    @Test
    fun toolReturnsOnlyCloseMatchesAsCheckableObjects() {
        val iv = ImageVectors(File("build/tmp/iv2-${System.nanoTime()}.bin"))
        iv.put(5, v(1f, 0f, 0f)); iv.put(6, v(0.97f, 0.24f, 0f)); iv.put(7, v(0.1f, 0.99f, 0f))
        val base = Fixture.docs().first { it.type == "sighting" }
        val tool = visualSearchTool({ v(1f, 0f, 0f) }, { iv }, { base })
        val evs = ArrayList<Doc>()
        val out = tool.run(JSONObject().put("looks_like", "a red sofa"), ToolCtx("where is the sofa", 0, emptyList(), null) { d -> evs.add(d); "E${evs.size}: ${d.text}" })
        out as ToolOut.Text
        // 5 (1.00) and 6 (0.97) kept, 7 (0.10) below the floor
        assertEquals(listOf("5.jpg", "6.jpg"), evs.map { it.frame })
        assertTrue(evs.all { it.type == "object" && it.name == "a red sofa" })
        val none = visualSearchTool({ v(0f, 0f, 1f) }, { iv }, { base }).run(JSONObject().put("looks_like", "a giraffe"),
            ToolCtx("", 0, emptyList(), null) { "E1" }) as ToolOut.Text
        assertTrue(none.text.startsWith("No stored picture"))
    }

    @Test
    fun agentGetsTheToolInItsList() {
        scriptedModel(toolCall("answer", JSONObject().put("label", "DONT_KNOW").put("text", "No.").put("evidence", org.json.JSONArray()))).use { srv ->
            val llm = Llm(LlmConfig(srv.url + "/v1", "m", "k", "")).apply { gate = PrivacyGate.OPEN }
            Agent(llm, prompts(), Asker(llm, prompts(), ParityTest.JvmImages, null)).apply { preSearch = false }
                .run("where did I see a red sofa", emptyList(), emptyList(), 0L,
                    extras = listOf(visualSearchTool({ null }, { ImageVectors(File("build/tmp/none.bin")) }, { null })))
            assertTrue(srv.bodies[0].contains("\"search_visual\""))
        }
    }
}
