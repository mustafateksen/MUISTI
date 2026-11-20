package com.muisti.privacy

import com.muisti.engine.Asker
import com.muisti.engine.Doc
import com.muisti.engine.Extractor
import com.muisti.engine.Images
import com.muisti.engine.Llm
import com.muisti.engine.LlmConfig
import com.muisti.engine.PrivacyBlocked
import com.muisti.engine.Prompts
import com.muisti.engine.CountingServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * P1.3: every path that can put an image in a request goes through Llm.imagePart -> PrivacyGate. With a gate that
 * says "private" or throws, each path sends NOTHING (a local server counts requests).
 */
class PrivacyGateTest {
    private lateinit var server: CountingServer
    private val hits get() = server.hits
    private lateinit var llm: Llm
    private lateinit var prompts: Prompts
    private val jpeg = byteArrayOf(-1, -40, -1, -32, 0, 16)   // content does not matter: the gate decides
    private val noResize = object : Images { override fun downscale(jpeg: ByteArray, longSide: Int) = jpeg }

    @Before
    fun up() {
        server = CountingServer { _, _ -> """{"choices":[{"message":{"content":"{\"present\": true, \"where\": \"x\"}"},"finish_reason":"stop"}]}""" }
        llm = Llm(LlmConfig(server.url + "/v1", "m", "k", ""))
        val repo = File(System.getProperty("muisti.repo") ?: "../..")
        prompts = Prompts(File(repo, "nemotron/docs/prompts.json").readText())
    }

    @After
    fun down() = server.close()

    private val gates = mapOf(
        "private" to PrivacyGate { Decision.Block("a bathroom") },
        "throws" to PrivacyGate { throw IllegalStateException("model crashed") },
        "default" to null,   // Llm's own default: CLOSED
    )

    private fun each(body: (String) -> Unit) {
        for ((name, g) in gates) {
            llm.gate = g ?: PrivacyGate.CLOSED
            hits.set(0)
            body(name)
            assertEquals("gate '$name': nothing may be sent", 0, hits.get())
        }
    }

    @Test
    fun imagePartThrows() = each { name ->
        try { llm.imagePart(jpeg); fail("$name: imagePart must throw") } catch (e: PrivacyBlocked) {}
    }

    @Test
    fun ingestExtractSendsNothing() = each { name ->
        try { Extractor(llm, prompts, noResize).extract(jpeg, listOf("APTEEKKI")); fail("$name: extract must throw") } catch (e: PrivacyBlocked) {}
    }

    @Test
    fun liveLookSendsNothing() = each {
        val a = Asker(llm, prompts, noResize, null)
        val say = a.liveLook("what is this?", jpeg)
        assertTrue(say, say.contains("private"))
    }

    @Test
    fun lookAgainSendsNothing() = each {
        val dir = File("build/gate_test").apply { mkdirs() }
        File(dir, "1.jpg").writeBytes(jpeg)
        val d = Doc("object", 0, "1.jpg", dir.path, "t", false, "keys", "item", text = "Seen object: keys")
        val a = Asker(llm, prompts, noResize, null)
        val r = a.lookAgain(d)
        assertTrue(r.second, r.second.contains("private"))
    }

    @Test
    fun allowedImagesDoGo() {
        llm.gate = PrivacyGate.OPEN
        hits.set(0)
        val a = Asker(llm, prompts, noResize, null)
        a.liveLook("q", jpeg)
        assertEquals(1, hits.get())
    }

    /** No other code builds an image request: "data:image" / "image_url" appear only in Llm.kt. */
    @Test
    fun onlyLlmBuildsImageRequests() {
        val src = File("src/main/java")
        val offenders = src.walk().filter { it.extension == "kt" && it.name != "Llm.kt" }
            .filter { f -> f.readText().let { it.contains("data:image") || it.contains("\"image_url\"") || it.contains("\"video_url\"") } }
            .map { it.path }.toList()
        assertTrue("image requests built outside Llm.imagePart: $offenders", offenders.isEmpty())
    }
}
